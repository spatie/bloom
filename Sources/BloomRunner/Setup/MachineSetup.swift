import BloomCore
import Foundation
import Synchronization

/// Brings the machine's one workspace up: the checkout, the repository's scripts, then its
/// services.
///
/// **Every create is cold.** A Sprite cannot start from another's checkpoint, so the first start of
/// Bloom Runner runs the whole of it: clone, create the branch, `prepare`, `setup`, `resume`, then
/// the services. Every later start, after an update or a cold wake that dropped memory, runs only
/// `resume` and the services, because `resume` is the script that exists to pick fresh environment
/// up and the rest has already happened on this disk. See docs/REMOTE-WORKSPACES.md, "Setup".
///
/// **A failed step ends the sequence, and the next start tries the whole of it again.** Only a
/// sequence that succeeded is recorded as done. A `setup` that failed because a team variable was
/// missing is the ordinary case, and the fix for it (setting the variable on runbloom.app, which
/// restarts nothing) should not need a person to find a "run setup again" button. Prompts are let go
/// after a failure all the same, as on the Mac, because an agent can read the log and fix the
/// script; the services wait for a setup that succeeded, because a dev server started against a
/// half-migrated database only adds a second error to read.
///
/// Ordinary variables are shared by repository scripts and services. Secrets are fetched for one
/// launch only: setup receives setup scope, and each service asks for its stable id at launch.
public actor MachineSetup {
    public typealias IsolateNetworkGit = @Sendable (AgentLaunch) async -> RemoteRunnerFactory.IsolatedLaunch?
    public static let completedSetting = "remote.setup.completed"
    /// Whether the last whole sequence skipped the scripts because the workspace asked for no
    /// setup, as distinct from having run them.
    ///
    /// **`completedSetting` cannot answer this**, because it is set either way: a workspace that
    /// asked for no setup has finished its sequence exactly as much as one that ran three scripts.
    /// What needs telling apart is a machine where nothing was ever installed from one where setup
    /// really ran, and there is one machine in the world of the second kind: a workspace created
    /// with the box unticked, whose runner was older than this key and set it up anyway. Updating
    /// that machine must not stop its services or rewrite its setup log with a sentence saying
    /// nothing was run, because something was, and its preview is somebody's working project.
    static let skippedSetting = "remote.setup.skipped"

    public struct Timeouts: Sendable, Hashable {
        public var clone: Duration
        public var prepare: Duration
        public var setup: Duration
        public var resume: Duration

        public init(clone: Duration, prepare: Duration, setup: Duration, resume: Duration) {
            self.clone = clone
            self.prepare = prepare
            self.setup = setup
            self.resume = resume
        }

        /// An hour for `prepare` and `setup`, because apt, a database server and a cold
        /// `composer install` together measured two and a half minutes for one project and nobody
        /// has measured the slowest. Ten minutes for `resume`, which runs on every wake and should
        /// never be doing that kind of work.
        public static let standard = Timeouts(clone: .seconds(30 * 60), prepare: .seconds(60 * 60), setup: .seconds(60 * 60), resume: .seconds(10 * 60))
    }

    /// How long a timed-out step has between SIGTERM and SIGKILL.
    static let stopGrace = Duration.seconds(10)

    private let runtime: WorkspaceRuntime
    private let store: Store
    private let configuration: MachineConfiguration
    private let layout: MachineLayout
    private let machineEnvironment: MachineEnvironment
    private let services: ServiceSupervisor
    private let gitTools: MachineGitTools
    private let cloneURL: @Sendable (_ repository: String) -> String
    /// The user scripts and services run as, or nil where there is none. See `MachineSandbox`.
    private let sandbox: MachineSandbox?
    private let isolateNetworkGit: IsolateNetworkGit
    private let syncServiceManifest: @Sendable ([RemoteProjectSettings.Service]) async throws -> Void
    private let gitGlobalConfig: String?
    private let timeouts: Timeouts
    /// How long this instance waits; a test cannot sit through five minutes to prove a sentence.
    private let stallAfter: TimeInterval
    private var isRunning = false
    /// Who asked for the run in hand to stop, once somebody has. See `stop(by:)`.
    private var stoppedBy: String?
    /// What setup is doing now and since when, for the stall watchdog. Nil between runs.
    private var activity: (name: String, since: Date)?

    /// The `gh` wrapper's directory. Put it first on an agent's PATH, so the agent's `gh` asks
    /// Bloom Runner for a token too.
    public nonisolated let binDirectory: String

    /// - Parameters:
    ///   - serverExecutable: the Bloom Runner that git and the `gh` wrapper call back into.
    ///   - cloneURL: where `owner/name` is cloned from. GitHub, except in tests.
    ///   - gitGlobalConfig: a file to use as git's global configuration instead of the machine
    ///     user's `~/.gitconfig`, for tests. Handed to every script and service as
    ///     `GIT_CONFIG_GLOBAL`.
    public init(
        runtime: WorkspaceRuntime,
        store: Store,
        configuration: MachineConfiguration,
        layout: MachineLayout,
        environment: MachineEnvironment,
        services: ServiceSupervisor,
        serverExecutable: String = MachineSetup.currentExecutable,
        cloneURL: @escaping @Sendable (_ repository: String) -> String = MachineSetup.gitHubCloneURL,
        gitGlobalConfig: String? = nil,
        personBoundSharedDirectory: String = MachineSandbox.personBoundSharedDirectory,
        isolateNetworkGit: @escaping IsolateNetworkGit,
        syncServiceManifest: @escaping @Sendable ([RemoteProjectSettings.Service]) async throws -> Void = { _ in },
        timeouts: Timeouts = .standard,
        stallAfter: TimeInterval = MachineSetup.stallAfter,
        sandbox: MachineSandbox? = nil
    ) {
        self.sandbox = sandbox
        self.isolateNetworkGit = isolateNetworkGit
        self.syncServiceManifest = syncServiceManifest
        self.runtime = runtime
        self.store = store
        self.configuration = configuration
        self.layout = layout
        machineEnvironment = environment
        self.services = services
        gitTools = MachineGitTools(
            serverExecutable: serverExecutable, repository: configuration.repository,
            sharedDirectory: personBoundSharedDirectory
        )
        self.cloneURL = cloneURL
        self.gitGlobalConfig = gitGlobalConfig
        self.timeouts = timeouts
        self.stallAfter = stallAfter
        binDirectory = gitTools.binDirectory
    }

    /// Never a token in the URL: the credential helper supplies one when git asks.
    public static let gitHubCloneURL: @Sendable (String) -> String = { "https://github.com/\($0).git" }

    /// This process's path as it was started, made absolute but with symlinks left alone:
    /// `/opt/bloom/current/bin/Bloom Runner` has to stay `current`, because the versioned directory
    /// it points at today is deleted by a later update.
    public static var currentExecutable: String {
        let argument = CommandLine.arguments.first ?? "bloom-runner"
        if argument.hasPrefix("/") { return URL(fileURLWithPath: argument).standardized.path }
        if argument.contains("/") {
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(argument).standardized.path
        }
        return Shell.which(argument) ?? argument
    }

    private var setupDirectory: String { layout.dataDirectory + "/setup" }

    /// What Bloom Runner calls at every start.
    public func run() async {
        let completed = (try? await store.setting(Self.completedSetting)) == "1"
        let watchdog = watchForStalls()
        defer { watchdog.cancel() }
        if completed {
            await resumeAfterRestart()
        } else {
            await runWholeSequence()
        }
    }

    /// How long one part of setup may go without moving before the machine says so, and how often
    /// it says so after that.
    public static let stallAfter: TimeInterval = 5 * 60

    /// **A machine stuck in setup answers everything you ask it except the one thing that matters.**
    ///
    /// Measured on a Sprite: a `git config` child exited one second into the machine's life and was
    /// never reaped, `Process.run()` never returned, and setup sat in that one call for eighteen
    /// minutes. Health answered, RPC answered, the summary said `setting_up`, and the shutdown when
    /// it finally came was clean in eighteen milliseconds. Nothing anywhere said the workspace was
    /// never going to exist. So this cannot be built on "is the server alive", because it was: it
    /// is built on "has this step moved", which is the only question with a useful answer.
    ///
    /// It says so and does nothing else. Restarting the service clears that hang, and this knows
    /// it, but a watchdog that restarts a machine is a third thing that reverts a release
    /// (`Tools/bootstrap-machine.sh` has the other two) and the sentence is what was missing.
    /// runbloom.app is the side that can see a machine from outside and act on it.
    private func watchForStalls() -> Task<Void, Never> {
        let interval = Duration.seconds(min(stallAfter / 2, 30))
        return Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                // A child that was being read and is now gone is a step ending under this tick,
                // not a stall: reading it as "cannot tell" gave restart advice for a step that had
                // just finished, which the Linux job caught with a `sleep 4` exiting mid-tick.
                guard let childEnded = await self?.checkLiveness(), !childEnded else { continue }
                await self?.reportStall()
            }
        }
    }

    private var stalledSince: Date?
    /// The script running now, for the liveness read. Nil between steps.
    private var child: StreamingProcess?
    private var lastReading: StepLiveness.Reading?
    private var lastVerdict: StepLiveness.Verdict?

    /// What is alive under the step in hand, told to runbloom.app so that its decision to restart a
    /// machine rests on something the machine observed rather than on a timestamp going stale.
    ///
    /// **The evidence is about the child, never about this process.** During the one hang anybody
    /// has seen, the runner was healthy in every way something could be asked: it answered health,
    /// answered RPC, posted summaries, and this very watchdog woke on its timer, all over a child
    /// that had been dead for seventeen minutes. Anything sourced from here would have called that
    /// hang healthy for its whole duration. See `StepLiveness`.
    /// Returns whether a child that was being read has just gone, which the caller takes as the
    /// step ending rather than as a machine that cannot tell.
    private func checkLiveness() async -> Bool {
        guard let pid = child?.processIdentifier, pid > 0, let reading = StepLiveness.read(child: pid) else {
            // Between steps, or not on a machine. No signal is not a stall, and saying nothing is
            // how that is said.
            guard lastVerdict != nil else { return false }
            lastReading = nil
            lastVerdict = nil
            await runtime.setupLivenessChanged(nil)
            return true
        }
        let verdict = StepLiveness.verdict(reading, since: lastReading)
        lastReading = reading
        lastVerdict = verdict
        await runtime.setupLivenessChanged(
            .init(verdict: verdict.rawValue, running: reading.running, defunct: reading.defunct, at: Date())
        )
        return false
    }

    private func reportStall() async {
        guard let activity else {
            stalledSince = nil
            return
        }
        // Output is progress. A step that is printing is working, whatever its own clock says.
        let lastMovement = max(activity.since, await currentLog?.lastWriteAt ?? activity.since)
        let waiting = Date().timeIntervalSince(lastMovement)
        guard waiting >= stallAfter else { return }
        // Once per interval rather than once per tick, and again when the same step is still there
        // the next interval: a machine that is stuck for an hour should say so twelve times, not
        // once at the start where nobody was looking yet.
        if let stalledSince, Date().timeIntervalSince(stalledSince) < stallAfter { return }
        stalledSince = Date()
        let waited = waiting >= 60 ? "\(Int(waiting / 60)) minutes" : "\(Int(waiting)) seconds"
        // **The advice is given only when it is correct.** This used to end by suggesting a restart
        // whatever was happening, which is advice handed to everybody whose `composer install` is
        // four minutes into being perfectly fine, and advice that is usually wrong is advice
        // somebody learns to ignore on the day it is right. The verdict is the same signal the
        // summary carries, so there is one definition of alive rather than two that drift, and it
        // is spent here on the difference between reassurance and an instruction.
        let quiet = "Setup has been in \(activity.name) for \(waited) with nothing new. "
        let sentence: String
        switch lastVerdict {
        case .working:
            sentence = quiet + "Something under it is still working, so this is a quiet step rather "
                + "than a stuck one."
        case .waiting:
            sentence = quiet + "Something is still running under it, waiting on something rather than "
                + "using the processor. Nothing needs doing."
        case .nothingAlive, nil:
            // Nil is a machine that cannot tell rather than one saying the step is dead, and the
            // advice is the same in both: this is the only shape where a restart is the answer, and
            // saying why is what stops it reading as a ritual.
            let because = lastVerdict == nil
                ? "If it never moves, "
                : "Nothing is running under it at all. "
            sentence = quiet + because
                + "restarting this machine's server clears it: the one case measured was a "
                + "subprocess launch that never returned, and a restart ran the same step at once."
        }
        await currentLog?.note(sentence)
        FileHandle.standardError.write(Data("bloom-runner: \(sentence)\n".utf8))
    }

    /// The log of the run in hand, so the watchdog can write into what a person is watching.
    private var currentLog: SetupLog?

    /// Setup moved on to something. The name is what the watchdog says, so it is what somebody
    /// reading a stuck machine sees: `configuring git` rather than `step 0`.
    private func moved(to name: String) {
        activity = (name, Date())
        stalledSince = nil
    }

    /// `run_setup` by hand: the project's setup script again, as the whole sequence runs it. Nil when
    /// a run is already in progress.
    ///
    /// **Through this, never through the Mac's `WorkspaceManager.runSetup`.** That one launches an
    /// inline script with zsh, and a machine is Ubuntu with no zsh, so a setup somebody asked for by
    /// hand on a machine failed before running a line; the Linux job found it on 19 September 2026.
    /// Here it is bash, with the same log, the same stall watchdog and the same `stop(by:)`.
    public func rerunSetup() async -> Bool? {
        guard !isRunning else { return nil }
        isRunning = true
        stoppedBy = nil
        didWork = false
        defer { isRunning = false }
        let watchdog = watchForStalls()
        defer { watchdog.cancel() }
        let log = SetupLog(store: store, workspaceID: runtime.workspaceID, directory: setupDirectory)
        currentLog = log
        defer { currentLog = nil; activity = nil }
        let environment = await scriptEnvironment()
        let scripts = MachineScripts.load(repo: layout.worktree)
        var succeeded = await runScript("setup", scripts.setup, timeout: timeouts.setup, environment: environment,
                                        log: log, continuing: false)
        if let stoppedBy {
            await log.note(Self.stoppedNote(by: stoppedBy))
            succeeded = false
        }
        await settle(log: log, succeeded: succeeded)
        return succeeded
    }

    /// Clone, `prepare`, `setup`, `resume`, then the services. Returns whether setup succeeded.
    @discardableResult
    public func runWholeSequence() async -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        stoppedBy = nil
        defer { isRunning = false }

        let log = SetupLog(store: store, workspaceID: runtime.workspaceID, directory: setupDirectory)
        currentLog = log
        defer { currentLog = nil; activity = nil }
        // A run the machine was stopped in the middle of left its output in the row; a person
        // watching setup should see this run added to it rather than the first attempt vanishing.
        let interrupted = (try? await store.workspace(id: runtime.workspaceID))?.setupState == .running

        // **The first two are steps, and they did not used to be.** Before this, a brand new
        // workspace said `pending` with no step through a call to runbloom.app and the whole of
        // the git configuration, so **the first thing anybody saw of a Cloud workspace was nothing
        // happening**, and this is the phase the one measured eighteen-minute hang sat in. A
        // phase with no name is a phase nobody can be told about.
        await begin("environment", log: log, continuing: interrupted)
        if interrupted { await log.note(Self.startingAgainNote) }
        do {
            try await machineEnvironment.requiredRefresh()
        } catch {
            await log.note("Bloom could not read a valid scoped environment, so no repository code ran.")
            await log.endStep()
            didWork = true
            await settle(log: log, succeeded: false)
            return false
        }
        let environment = await scriptEnvironment()
        await log.endStep()
        await begin("git", log: log, continuing: interrupted)
        await configureGit(log: log)
        await log.endStep()

        var succeeded = await cloneIfNeeded(environment: environment, log: log, continuing: interrupted)
        // **The clone is the Runner's, so the sandbox user has to be let into it.** Provisioning did
        // this at install, when there was no worktree yet, and it is idempotent, so it is run again
        // here rather than repeating what it does. Its failure is not setup's failure: the Runner
        // asks `MachineSandbox.available()` for whether to sandbox at all.
        if succeeded, sandbox != nil, FileManager.default.isExecutableFile(atPath: Self.provisionScript) {
            _ = await runProcess(Self.provisionScript, [], directory: layout.worktree, timeout: .seconds(120),
                                 environment: environment, log: log)
        }
        let scripts = MachineScripts.load(repo: layout.worktree)
        if succeeded {
            do {
                try await syncServiceManifest(scripts.services)
            } catch {
                // Naming the error, because without it this sentence is the whole of what a person
                // gets: a setup that failed, a clone that plainly worked, and nothing to act on.
                await log.note(
                    "Bloom could not register the repository's service identities, so no repository "
                        + "code ran. The reason was: \(error)"
                )
                succeeded = false
            }
        }
        if succeeded, configuration.runsSetup {
            for problem in scripts.problems { await log.note(problem) }
            if !scripts.hasCloudSetup { await log.note(Self.noCloudSetupNote(hasSetupScript: scripts.setup != nil)) }
            let steps: [(String, ScriptLaunch?, Duration)] = [
                ("prepare", scripts.prepare, timeouts.prepare),
                ("setup", scripts.setup, timeouts.setup),
                ("resume", scripts.resume, timeouts.resume),
            ]
            // Root for this one run only, and only on code nobody has touched yet.
            let pristine = await isPristineBaseCheckout()
            let privileged = !interrupted && pristine
            for (name, launch, timeout) in steps where succeeded && stoppedBy == nil {
                succeeded = await runScript(name, launch, timeout: timeout, environment: environment, log: log,
                                            continuing: interrupted, privileged: privileged)
            }
            if privileged { await shareWorktreeWithTheGroup() }
            if !privileged, sandbox != nil {
                await log.note("Setup ran as \(sandbox?.user ?? "the sandbox user"), which cannot install system packages, "
                    + "because this workspace did not start from \(configuration.baseBranch) as it stands.")
            }
        } else if succeeded {
            await log.note(Self.setupNotAskedForNote(hasServices: !scripts.services.isEmpty))
        }
        try? await store.setSetting(Self.skippedSetting, configuration.runsSetup ? "0" : "1")
        if await interruptedByShutdown(log: log) { return false }
        // A person stopped it: nothing after the step they stopped runs, services included, and the
        // run is filed as failed with a sentence that says it was stopped rather than broke.
        if let stoppedBy {
            await log.note(Self.stoppedNote(by: stoppedBy))
            succeeded = false
        }
        if succeeded {
            // Set whether or not the scripts ran: a workspace that asked for no setup has finished
            // its sequence exactly as much as one that ran three scripts, and the next start must
            // resume rather than begin again.
            try? await store.setSetting(Self.completedSetting, "1")
            if configuration.runsSetup {
                await startServices(scripts.services, environment: environment, log: log, continuing: interrupted)
            }
        }
        await settle(log: log, succeeded: succeeded)
        return succeeded
    }

    /// Starting the project's services, as a step of its own **before** setup is reported finished.
    ///
    /// **"Setup succeeded" used to be said while nothing was running yet.** The services were
    /// started after the outcome, and a service with a readiness check has up to five minutes, so
    /// the ordinary first impression was a workspace that said it was ready beside a preview that
    /// was blank, with nothing on screen to explain the gap. Launching them inside a step closes
    /// the part that is honestly closable: **this waits for them to be launched, not for them to be
    /// ready**, because prompts are held until setup finishes and holding somebody's first prompt
    /// for five minutes to be tidier about a caption would be the worse trade. Readiness after that
    /// is on the workspace record, service by service.
    private func startServices(
        _ services: [RemoteProjectSettings.Service], environment: [String: String], log: SetupLog, continuing: Bool
    ) async {
        guard !services.isEmpty else { return }
        await begin("services", log: log, continuing: continuing)
        await self.services.start(services, environment: environment)
        await log.note("Started \(services.count == 1 ? "1 service" : "\(services.count) services"). "
            + "Whether each is ready is on the workspace itself.")
        await log.endStep()
    }

    /// `resume` with fresh environment, then the services.
    @discardableResult
    public func resumeAfterRestart() async -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        defer { isRunning = false }

        moved(to: "reading the team's environment")
        do {
            try await machineEnvironment.requiredRefresh()
        } catch {
            let log = SetupLog(store: store, workspaceID: runtime.workspaceID, directory: setupDirectory)
            await log.begin(continuing: true)
            await log.startStep("environment")
            await log.note("Bloom could not read a valid scoped environment, so resume and services did not run.")
            await log.endStep()
            didWork = true
            await settle(log: log, succeeded: false)
            return false
        }
        let environment = await scriptEnvironment()
        let log = SetupLog(store: store, workspaceID: runtime.workspaceID, directory: setupDirectory)
        currentLog = log
        defer { currentLog = nil; activity = nil }
        moved(to: "configuring git")
        await configureGit(log: log)
        let scripts = MachineScripts.load(repo: layout.worktree)
        do {
            try await syncServiceManifest(scripts.services)
        } catch {
            await log.note("Bloom could not register the repository's service identities, so resume and services did not run.")
            await settle(log: log, succeeded: false)
            return false
        }
        // A workspace that asked for no setup asks for none at every start, not only the first.
        // `resume` is one of the three scripts, and a service is declared in the same settings file
        // they are, so starting one here would run half of what was refused.
        //
        // Unless setup has actually run here, which is a machine whose runner was older than the
        // key and set it up before anybody could honour it. Stopping its services and replacing its
        // log with "nothing was run" would be both untrue and destructive, so such a machine carries
        // on as it was and says why.
        if !configuration.runsSetup {
            // Absent means an older runner finished the sequence, and an older runner always ran
            // setup: this is the machine the setting exists for, so absence must read as "it ran"
            // rather than as "we do not know". Getting this the other way round is what would stop
            // that machine's services on the very update meant to help it.
            let skippedBefore = (try? await store.setting(Self.skippedSetting)) == "1"
            guard skippedBefore else {
                await log.note(Self.setupRanBeforeNote)
                moved(to: "resume")
                let resumed = await runScript("resume", scripts.resume, timeout: timeouts.resume,
                                              environment: environment, log: log, continuing: true)
                if await interruptedByShutdown(log: log) { return false }
                if resumed { await startServices(scripts.services, environment: environment, log: log, continuing: true) }
                await settle(log: log, succeeded: resumed)
                return resumed
            }
            await log.note(Self.setupNotAskedForNote(hasServices: !scripts.services.isEmpty))
            await settle(log: log, succeeded: true)
            return true
        }
        moved(to: "resume")
        let succeeded = await runScript("resume", scripts.resume, timeout: timeouts.resume, environment: environment, log: log, continuing: true)
        if await interruptedByShutdown(log: log) { return false }
        // Started before the outcome is reported, and inside a step, for the reason in
        // `startServices`: "setup succeeded" beside a blank preview is the machine saying something
        // untrue at the moment somebody is looking hardest.
        if succeeded { await startServices(scripts.services, environment: environment, log: log, continuing: true) }
        await settle(log: log, succeeded: succeeded)
        return succeeded
    }

    /// Stops the services and starts them again with the environment as it is now, for when
    /// runbloom.app says the team or project environment changed.
    public func restartServices() async {
        await services.restartAll(environment: await scriptEnvironment())
    }

    /// The machine's own non-secret environment with Bloom's variables on top.
    public func scriptEnvironment() async -> [String: String] {
        var environment = Shell.environment()
        for (key, value) in await machineEnvironment.variables { environment[key] = value }
        // The same names the Mac hands a setup script, because repositories in the wild already
        // read them: a script that starts with `set -u` and `cd "$BLOOM_ROOT_PATH"` fails on an
        // unbound variable before it reaches anything a machine could not do. On a machine the
        // clone is both the worktree and the repository root, and there is one workspace, so the
        // pair carry the same path.
        let variables = WorkspaceScriptVariables(
            isLocal: false, workspaceName: WorkspaceScriptVariables.workspaceName(branch: configuration.branch),
            workspaceID: configuration.workspaceID, workspacePath: layout.worktree,
            projectName: Self.projectName(repository: configuration.repository), rootPath: layout.worktree,
            defaultBranch: configuration.baseBranch, port: layout.appPort
        )
        environment.merge(variables.environment) { _, script in script }
        environment["BLOOM_PUBLIC_URL"] = configuration.publicURL
        environment["BLOOM_PUBLIC_HOST"] = configuration.publicHost
        environment["BLOOM_APP_PORT"] = String(layout.appPort)
        // The other half of the port contract: which numbers are already taken. A project that
        // picks one of these crash-loops with `Address already in use`, and until this existed
        // there was nowhere it could have read them from.
        environment["BLOOM_RESERVED_PORTS"] = layout.reservedPorts.map { String($0.port) }.joined(separator: ",")
        environment["BLOOM_WORKSPACE_ID"] = configuration.workspaceID
        environment["BLOOM_BRANCH"] = configuration.branch
        environment["BLOOM_REPOSITORY"] = configuration.repository
        environment["BLOOM_DATA_DIR"] = layout.dataDirectory
        environment["BLOOM_RUNNER_PORT"] = String(layout.serverPort)
        environment["PATH"] = binDirectory + ":" + (environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin")
        // A missing credential must fail the command, not leave it waiting for a password on a
        // terminal nobody is at.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        if let gitGlobalConfig { environment["GIT_CONFIG_GLOBAL"] = gitGlobalConfig }
        return ProviderCredentialEnvironment.untrustedProcess(environment)
    }

    /// The repository's own name rather than the clone's folder, which on a machine is always
    /// `workspace` and would give every project the same database name.
    static func projectName(repository: String) -> String {
        WorkspaceScriptVariables.identifier(repository.split(separator: "/").last.map(String.init) ?? repository)
    }

    /// What somebody is told when the workspace itself asked for no setup.
    ///
    /// **A sentence rather than an empty log.** A workspace whose setup log is blank and whose
    /// state is `skipped` reads as something that went wrong quietly, which is what a person
    /// looking at a machine assumes about any silence. This says the machine did what it was asked
    /// and where to go from here, and it names the services too, because a repository that
    /// declares one and does not get it is the surprising half.
    static func setupNotAskedForNote(hasServices: Bool) -> String {
        let start = "This workspace was created with setup turned off, so the repository was cloned "
            + "and nothing else was run."
        let ending = " Open a terminal to set it up by hand, or create the workspace again with setup on."
        return hasServices
            ? start + " The services this project declares were not started either, because they "
                + "expect what setup installs." + ending
            : start + ending
    }

    /// Said when a machine picks setup up again after stopping in the middle of it, so that seeing
    /// the same steps twice reads as an explanation rather than as a fault.
    static let startingAgainNote = "Starting again: this machine stopped while it was setting up."

    static func stoppedNote(by name: String) -> String {
        let who = name.isEmpty ? "Somebody" : name
        return "\(who) stopped setup. What finished before stays installed; run setup again to do the rest."
    }

    /// Stops the run in hand: the step running now is ended, and nothing after it starts.
    ///
    /// **Not a cancellation of the run's task.** Cancelling is what a shutdown does, and it files the
    /// run as interrupted by the machine, which comes back and runs it again by itself; a person
    /// stopping setup is a different fact, and the opening prompt that runs after setup still has to
    /// run. So the step's process is ended here and the run settles as failed, with a sentence
    /// saying who stopped it. Answers false when nothing is running.
    public func stop(by name: String) async -> Bool {
        guard isRunning, stoppedBy == nil else { return false }
        stoppedBy = name
        child?.terminate()
        return true
    }

    /// What the one machine in the middle is told: setup turned off, and setup already run.
    static let setupRanBeforeNote =
        "This workspace was created with setup turned off, but it was set up anyway before this "
        + "machine's server understood that. What is installed stays, and its services keep "
        + "running, because stopping them now would break a project that works."

    /// What somebody is told before a repository with no Cloud workspace setup is set up anyway.
    static func noCloudSetupNote(hasSetupScript: Bool) -> String {
        let start = "This project has no Bloom Cloud workspace setup yet. Add .bloom/settings.toml with a "
            + "[scripts] prepare (what the machine needs installed), setup (this workspace's own "
            + "setup) and [[services]] (what to run and how to know it is up)."
        return hasSetupScript
            ? start + " Until then the project's existing setup script runs as it is, and a script "
                + "written for a Mac may not work on a machine."
            : start + " Nothing is set up for now, so the worktree is the repository as it was cloned."
    }

    // MARK: - Steps

    /// A shutdown cancels setup, and the step it stopped exits non-zero. Filing that as a failure
    /// would tell runbloom.app setup failed and let the queue start turns while the machine goes
    /// down, so it is filed as interrupted and nothing else happens.
    private func interruptedByShutdown(log: SetupLog) async -> Bool {
        guard Task.isCancelled else { return false }
        if await log.hasBegun { await log.interrupt() }
        return true
    }

    /// The row's state and the runtime's record both say how it ended. A sequence where nothing
    /// ran is filed as skipped, as the Mac files a workspace with no setup script.
    /// **"Did anything run" is asked of the steps, not of the log.** It used to be `log.hasBegun`,
    /// which was the same question while the first thing to write to the log was the clone. Naming
    /// the environment and git phases made every run begin the log, so that proxy would have filed
    /// every skipped run as a finished one. What is being asked is whether any *work* happened, so
    /// it is tracked where the work is.
    private func settle(log: SetupLog, succeeded: Bool) async {
        if didWork {
            await log.finish(succeeded: succeeded)
        } else {
            // **Closed first, then filed.** The row is `running` by now, because the phases before
            // any work are steps of their own, and `runSkipped` is refused from `running` for a
            // reason that still holds where it was written: on the Mac, reaching it from there
            // means filing a live process as a run that never happened. So the run is ended
            // honestly and then recorded as having done nothing, which is two events and two true
            // statements rather than one weakened rule.
            // Only if it was opened. On a later start nothing names a step before this, so the row
            // is still `pending` and finishing it would be refused, which is a recorded bug rather
            // than a harmless no-op.
            if await log.hasBegun { await log.finish(succeeded: true) }
            let notes = await log.noteText.trimmingCharacters(in: .newlines)
            _ = try? await store.update(workspaceID: runtime.workspaceID) { $0.apply(.runSkipped(note: notes.isEmpty ? nil : notes)) }
        }
        await runtime.setupFinished(succeeded: succeeded)
    }

    /// Whether this sequence did anything a person would call setting up: a clone, or a script.
    /// Reading the environment and configuring git are preparation and happen on every start.
    private var didWork = false

    private func begin(_ step: String, log: SetupLog, continuing: Bool) async {
        moved(to: step)
        await log.begin(continuing: continuing)
        await log.startStep(step)
        await runtime.setupStepStarted(step)
    }

    /// Writes the sole Git and gh wrapper path. Network configuration is fixed per invocation by
    /// `PersonBoundGitCommand`; no caller-controlled global helper is installed.
    private func configureGit(log: SetupLog) async {
        do {
            try gitTools.writeGhWrapper()
        } catch {
            await log.note("The gh wrapper could not be written to \(gitTools.ghWrapperPath): \(error.localizedDescription)")
        }
    }

    /// Whether the clone and its checkout both finished, recorded apart from `.git` existing:
    /// a clone killed by the watchdog or a checkout that failed leaves `.git` behind, and the next
    /// start would otherwise run the scripts on the default branch of a half-made repository.
    static let clonedSetting = "remote.setup.cloned"

    /// The checkout both accounts work in, remade before every clone.
    ///
    /// **Provisioning makes this directory and the line above deletes it**, which is correct, since
    /// a clone starts from nothing. What was missing is putting it back with the sharing it was
    /// given: the clone runs as `bloom-agent`, the Runner's home is 0751 so that account cannot
    /// create anything in it, and git answered "could not create work tree dir: Permission denied"
    /// on every workspace. Owned by the Runner, group `bloom-work`, setgid so that whatever either
    /// account writes stays shared, and group-writable so the other one can change it.
    private func makeSharedWorktree(_ worktree: String) {
        let parent = (worktree as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)

        #if canImport(Glibc)
        if let entry = MachineSandbox.sharedGroup.withCString({ getgrnam($0) }) {
            // uid_t(bitPattern:) of -1 leaves the owner alone, which is what chown wants here.
            _ = chown(worktree, uid_t(bitPattern: -1), entry.pointee.gr_gid)
        }
        _ = chmod(worktree, 0o2770)
        #endif
    }

    private func cloneIfNeeded(environment: [String: String], log: SetupLog, continuing: Bool = false) async -> Bool {
        let worktree = layout.worktree
        let cloned = (try? await store.setting(Self.clonedSetting)) == "1"
        // A setup that once completed had a whole clone, whatever the marker says.
        let completed = (try? await store.setting(Self.completedSetting)) == "1"
        if FileManager.default.fileExists(atPath: worktree + "/.git") && (cloned || completed) { return true }
        await begin("clone", log: log, continuing: continuing)
        didWork = true
        // Only an earlier attempt of this step has written here. Prompts wait for setup, so before
        // the clone is marked finished there is no work of anybody's in it to lose.
        try? FileManager.default.removeItem(atPath: worktree)
        makeSharedWorktree(worktree)
        var succeeded = await runProcess(
            "git", ["clone", cloneURL(configuration.repository), worktree],
            directory: nil, timeout: timeouts.clone, environment: environment, log: log,
            isolateNetworkGit: true
        )
        if succeeded {
            // The branch exists on GitHub when the workspace was made from one; otherwise it starts
            // from the base branch, untracked, so a first `git push -u` names its own upstream
            // rather than pushing into the base.
            let branch = configuration.branch
            let remote = try? await Shell.run(
                "git", ["rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(branch)"],
                cwd: worktree, environment: environment, timeout: .seconds(30)
            )
            let arguments = remote?.ok == true
                ? ["checkout", "-B", branch, "origin/\(branch)"]
                : ["checkout", "--no-track", "-B", branch, "origin/\(configuration.baseBranch)"]
            succeeded = await runProcess("git", arguments, directory: worktree, timeout: .seconds(5 * 60), environment: environment, log: log)
        }
        if succeeded, !Task.isCancelled {
            try? await store.setSetting(Self.clonedSetting, "1")
        } else if !Task.isCancelled {
            // git's own message says what went wrong to somebody who knows git; this says what to
            // do about the two that a person can act on.
            await log.note("\(configuration.repository) could not be cloned. Check that the repository still exists and that "
                + "Bloom's GitHub App is installed for it, then run setup again.")
        }
        await log.endStep()
        return succeeded
    }

    /// **`privileged` is the one exception to the sandbox, and it is narrow.** The first setup of a
    /// pristine checkout runs as this process's user, which has sudo, because that is what lets a
    /// project install packages, add a PPA or build a PHP extension. Everything after it, and any
    /// first setup on code that is not the base branch's own, runs as the sandbox user: an agent can
    /// edit a script, or the `package.json` a script runs, so a rerun as root would hand it root.
    /// Agreed with Freek on 19 September 2026. See `MachineSandbox` and H1 in the security review.
    private func runScript(
        _ step: String, _ launch: ScriptLaunch?, timeout: Duration, environment: [String: String], log: SetupLog,
        continuing: Bool, privileged: Bool = false
    ) async -> Bool {
        guard let launch else { return true }
        guard let command = MachineScripts.command(for: launch) else {
            // Skipped rather than failed, as on the Mac: a settings file pointing at a script that
            // is not committed yet should not cost anybody their workspace.
            if case .missing(let path) = launch {
                await log.begin(continuing: continuing)
                await log.note("The settings file names \(path) as the \(step) script and there is nothing there, so nothing ran.")
            }
            return true
        }
        await begin(step, log: log, continuing: continuing)
        didWork = true
        let processEnvironment: [String: String]
        if step == "setup" {
            do {
                let scoped = try await machineEnvironment.scoped(.setup(attemptID: UUID()), base: environment)
                processEnvironment = scoped.values
                await log.redact(scoped.redactions)
            } catch {
                await log.note("Bloom could not obtain the setup-only secrets, so the setup script did not run.")
                await log.endStep()
                return false
            }
        } else {
            processEnvironment = environment
        }
        let launched = privileged
            ? Self.asThisUserWithItsGroups(Self.withSharedUmask(command.executable, command.arguments))
            : (executable: command.executable, arguments: command.arguments)
        let succeeded = await runProcess(launched.executable, launched.arguments, directory: layout.worktree, timeout: timeout,
                                         environment: processEnvironment, log: log, step: step, privileged: privileged)
        if step == "setup" { await log.redact([]) }
        await log.endStep()
        return succeeded
    }

    /// **What a privileged setup wrote, handed to the group whatever umask it chose.** The Runner
    /// sets 002 before a script starts, and There There's own setup opens with `umask 077`, which
    /// is a sensible line on a laptop: `vendor/` came out 2700 and `.env` 600, owned by the
    /// machine's user, and every service, which runs as the sandbox user, died on
    /// `require(vendor/autoload.php): Permission denied`. A script cannot undo this, because it runs
    /// after the script has finished. Files the sandbox user owns are not ours to change and are
    /// skipped, which is what the ignored status is for.
    private func shareWorktreeWithTheGroup() async {
        #if canImport(Glibc)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["-R", "g+rwX", layout.worktree]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
        #endif
    }

    /// The command under a group-writable umask, set after any sudo hop because sudo replaces it.
    ///
    /// **A privileged setup is followed by scripts that are not.** It runs as the machine's user,
    /// and the Runner's umask is 077, so `composer install` left `vendor/` at 2700 and `.env` at
    /// 600, owned by that user. The resume script after the next restart runs as the sandbox user,
    /// could read neither, and failed on `file_put_contents(.env)`, as would the agent itself. The
    /// shared group exists so both of them can work in one checkout; this is what lets it.
    static func withSharedUmask(
        _ executable: String, _ arguments: [String]
    ) -> (executable: String, arguments: [String]) {
        ("/bin/sh", ["-c", "umask 002 && exec \"$@\"", "sh", executable] + arguments)
    }

    static func asThisUserWithItsGroups(
        _ command: (executable: String, arguments: [String])
    ) -> (executable: String, arguments: [String]) {
        asThisUserWithItsGroups(command.executable, command.arguments)
    }

    /// The same user this process runs as, but with the groups that user is actually in.
    ///
    /// **A supplementary group is fixed when a process starts, and this one starts without any.**
    /// The provider launches the Runner with an empty group set, `provision-sandbox.sh` adds the
    /// machine's user to the shared group afterwards, and nothing re-reads it: `/etc/group` says
    /// the user is a member and the running process disagrees. That did not matter while the
    /// worktree belonged to that same user. It matters now that the clone is performed under a
    /// person's own uid, which leaves the checkout owned by that uid and shared through the group
    /// this process has not got, so a privileged setup script could read the repository and not
    /// write to it. Laravel's `composer install` reported it as "The bootstrap/cache directory
    /// must be present and writable", on a directory that is present and is group writable.
    ///
    /// `sudo` calls `initgroups` for the target user, so asking it for the user we already are is
    /// the whole fix. Measured on a machine: the same PHP one line apart answers NO without this
    /// and YES with it. This is only for the privileged path, which already requires sudo to be
    /// there and usable; the sandboxed path gets its groups from the launcher.
    static func asThisUserWithItsGroups(
        _ executable: String, _ arguments: [String]
    ) -> (executable: String, arguments: [String]) {
        #if canImport(Glibc)
        // Only when it is actually missing. A machine with the group already in hand gains nothing
        // from a sudo hop, and a host that has no shared group at all is not one this applies to.
        guard let shared = MachineSandbox.sharedGroup.withCString({ getgrnam($0) })?.pointee.gr_gid,
              !currentGroups().contains(shared),
              let entry = getpwuid(getuid()), let name = entry.pointee.pw_name.map({ String(cString: $0) }),
              sudoAnswers()
        else { return (executable, arguments) }

        return ("/usr/bin/sudo", ["-n", "-E", "-u", name, "--", executable] + arguments)
        #else
        return (executable, arguments)
        #endif
    }

    #if canImport(Glibc)
    /// Whether sudo is here **and will answer without a password**, asked once.
    ///
    /// Its presence is not enough: the Linux CI job runs the test suite before it writes any
    /// sudoers rule, so a wrapped command there would not run at all and the setup output it was
    /// meant to stream never appeared. A machine has the rule from `provision-sandbox.sh`, which
    /// has to have succeeded for the Runner to start at all.
    private static let sudoAnswered = Mutex<Bool?>(nil)

    private static func sudoAnswers() -> Bool {
        if let known = sudoAnswered.withLock({ $0 }) { return known }
        var works = false
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/sudo") {
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            probe.arguments = ["-n", "true"]
            probe.standardOutput = FileHandle.nullDevice
            probe.standardError = FileHandle.nullDevice
            probe.standardInput = FileHandle.nullDevice
            works = (try? probe.run()) != nil
            if works {
                probe.waitUntilExit()
                works = probe.terminationStatus == 0
            }
        }
        sudoAnswered.withLock { $0 = works }

        return works
    }

    /// The supplementary groups this process holds, which is not what `/etc/group` says it should.
    private static func currentGroups() -> [gid_t] {
        let count = getgroups(0, nil)
        guard count > 0 else { return [] }
        var groups = [gid_t](repeating: 0, count: Int(count))
        guard getgroups(count, &groups) == count else { return [] }

        return groups
    }
    #endif

    private func runProcess(
        _ executable: String, _ arguments: [String], directory: String?, timeout: Duration, environment: [String: String],
        log: SetupLog, step: String? = nil, privileged: Bool = true, isolateNetworkGit: Bool = false
    ) async -> Bool {
        // The machine's own work (git, the clone, provisioning) is privileged by default; a script
        // from the repository asks for it explicitly and almost never gets it.
        let command = privileged ? nil : sandbox
        let launch = command.map { $0.wrap(executable: executable, arguments: arguments, path: environment["PATH"]) }
            ?? (executable: executable, arguments: arguments)
        let base = AgentLaunch(
            executable: launch.executable, arguments: launch.arguments,
            cwd: directory ?? FileManager.default.currentDirectoryPath,
            environment: command.map { $0.environment(environment) } ?? environment
        )
        let isolated: RemoteRunnerFactory.IsolatedLaunch?
        if isolateNetworkGit {
            isolated = await self.isolateNetworkGit(base)
            guard isolated != nil else {
                await log.note("Bloom could not obtain an isolated bootstrap GitHub grant, so the repository was not cloned.")
                return false
            }
        } else {
            isolated = nil
        }
        let actual = isolated?.launch ?? base
        let process = StreamingProcess(
            executable: actual.executable, arguments: actual.arguments, cwd: actual.cwd,
            environment: actual.environment, cleanup: isolated?.cleanup
        )
        // Held so the watchdog can ask what is alive under it. The pid is read at the moment of
        // asking rather than kept, because `lines` is what starts the process and there is no pid
        // until then.
        child = process
        defer { child = nil }
        let lines = process.lines
        let watchdog = Task<Bool, Never> {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return false
            }
            process.terminate()
            // Cancelled once the process has exited, and `kill` does nothing to a process that
            // has, so the second sleep ending early is harmless.
            try? await Task.sleep(for: Self.stopGrace)
            process.kill()
            return true
        }
        // A shutdown cancels this task, which ends `lines` and with it sends SIGTERM. A script that
        // ignores it would hold shutdown until its step timeout, up to an hour, so it gets the
        // same grace as the watchdog gives and is then killed.
        // Kept only while a sandboxed script runs, and only the tail: it is read to tell "this asked
        // for root" from an ordinary failure. See `SandboxRefusal`.
        let tail = Mutex<[String]>([])
        let watching = command != nil
        let ending = await withTaskCancellationHandler {
            do {
                for try await line in lines {
                    if watching {
                        tail.withLock { lines in
                            lines.append(line)
                            if lines.count > Self.refusalTail { lines.removeFirst() }
                        }
                    }
                    await log.append(line)
                }
            } catch {
                await log.append("[bloom] \(error)")
            }
            return await process.ending
        } onCancel: {
            process.terminate()
            Task {
                try? await Task.sleep(for: Self.stopGrace)
                process.kill()
            }
        }
        watchdog.cancel()
        if await watchdog.value {
            await log.note("This step took longer than \(Self.minutes(timeout)) and was stopped.")
            return false
        }
        if !ending.isSuccess {
            // Named, because a workspace's own summary shows the last lines of this and "exited
            // with status 1" alone does not say which of three scripts it was.
            //
            // **And how it ended rather than only its number.** A script killed by SIGPIPE was
            // reported as "exited with status 13", because Foundation puts the signal in
            // `terminationStatus`; somebody read that as the script's own verdict and spent twenty
            // actions rebuilding by hand what setup should have done. See `ProcessEnding`.
            await log.note(step.map { "The \($0) script \(ending.sentence)." } ?? "The script \(ending.sentence).")
            // What the failure really was, when it was root and not the project's own code.
            if let user = command?.user, let advice = SandboxRefusal.advice(lines: tail.withLock { $0 }, user: user) {
                await log.note(advice)
            }
        }
        return ending.isSuccess
    }

    /// Whether the checkout is the base branch as it stands, which is what "nobody has touched this
    /// code yet" means in practice: a workspace cut from `main` has HEAD at `origin/main`'s commit,
    /// while one started from somebody's pull request does not. Read from git rather than from a
    /// field, so it cannot be claimed.
    func isPristineBaseCheckout() async -> Bool {
        let base = configuration.baseBranch
        guard !base.isEmpty else { return false }
        guard let head = try? await Git.headSHA(of: layout.worktree),
              let tip = try? await Git.mergeBase("refs/remotes/origin/" + base, "HEAD", in: layout.worktree) else { return false }
        // The merge base of HEAD and the base branch is HEAD itself only when HEAD is on the base
        // branch, which is what a workspace cut from it looks like before anybody commits.
        return !head.isEmpty && head == tip
    }

    /// How many of a sandboxed script's last lines are kept to read a permission refusal out of.
    static let refusalTail = 40

    /// Provisioning, beside this build of the Runner. See `Tools/provision-sandbox.sh`.
    static let provisionScript = "/opt/bloom/current/bin/provision-sandbox.sh"

    static func minutes(_ duration: Duration) -> String {
        let seconds = duration.components.seconds
        let (count, unit) = seconds >= 60 ? (seconds / 60, "minute") : (seconds, "second")
        return "\(count) \(unit)\(count == 1 ? "" : "s")"
    }
}
