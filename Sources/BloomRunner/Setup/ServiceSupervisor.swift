import BloomCore
import Foundation

/// The project's `[[services]]`, run under Bloom Runner rather than as Sprite Services.
///
/// A Sprite Service restarts by itself on a cold wake, before `resume` has fetched fresh
/// environment, and cannot be deleted while another depends on it. So Bloom Runner is the only
/// Sprite Service, and it starts these after `resume`, in dependency order, with the environment
/// setup ran with. See docs/REMOTE-WORKSPACES.md, "Setup".
///
/// **A service is up when it runs, or when its ready check has passed if it has one.** A service
/// starts once everything it depends on is up, and stays running if a dependency crashes later:
/// restarting Vite because the app server restarted would only lose its connection to the browser.
/// A dependency whose check never passes leaves its dependents waiting, with a message saying
/// which one, because starting Horizon against a database that never came up only moves the error
/// somewhere harder to read.
public actor ServiceSupervisor {
    public typealias ScopedEnvironment = @Sendable (_ service: String, _ base: [String: String]) async throws
        -> ScopedProcessEnvironment
    public enum State: String, Sendable, Hashable {
        /// Waiting for a dependency to be up.
        case waiting
        /// Running, and its ready check has not passed yet.
        case starting
        case running
        /// Running, and its ready check did not pass before the deadline.
        case notReady = "not_ready"
        /// Exited, and will be started again after a wait.
        case crashed
        case stopped
    }

    public struct Status: Sendable, Hashable {
        public var name: String
        public var state: State
        /// How many times it has exited since it was started.
        public var restarts: Int
        /// A sentence for a person: what it is waiting for, or how it ended.
        public var message: String?
        /// The one the preview routes to, from the project's own `http = true`.
        public var isHTTP: Bool = false
    }

    public struct Tuning: Sendable, Hashable {
        public var readinessDeadline: Duration
        public var readinessInterval: Duration
        public var backoff: RestartBackoff
        public var stopGrace: Duration
        public var logLimit: Int

        public init(
            readinessDeadline: Duration = .seconds(300), readinessInterval: Duration = .milliseconds(500),
            backoff: RestartBackoff = .standard, stopGrace: Duration = .seconds(10), logLimit: Int = 10 * 1_048_576
        ) {
            self.readinessDeadline = readinessDeadline
            self.readinessInterval = readinessInterval
            self.backoff = backoff
            self.stopGrace = stopGrace
            self.logLimit = logLimit
        }

        public static let standard = Tuning()
    }

    private struct Entry {
        var service: RemoteProjectSettings.Service
        var state: State = .waiting
        var restarts = 0
        /// Whether the reserved-port sentence has been said about this service already.
        var saidAboutPorts = false
        var message: String?
        var up = false
        var process: SupervisedProcess?
        var readiness: Task<Void, Never>?
    }

    private let layout: MachineLayout
    /// Told whenever the states change, so a client sees a service that never started. Pulling this
    /// was enough while the only reader was the preview's failure page; it is not enough now that
    /// the workspace record carries it, because nothing asks a machine for a page it never opens.
    private let observer: (@Sendable ([Status]) async -> Void)?
    private var announced: [Status]?
    private let tuning: Tuning
    private let scopedEnvironment: ScopedEnvironment
    private var services: [RemoteProjectSettings.Service] = []
    private var environment: [String: String] = [:]
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    /// Bumped by every start and stop, so an event from a process that belonged to an earlier
    /// start cannot move the state of the one that replaced it.
    private var generation = 0
    private var operation: Task<Void, Never>?

    /// The user a service runs as, or nil for this process's own. A service is the project's code,
    /// so it belongs in the sandbox with the agents and the scripts. See `MachineSandbox`.
    private let sandbox: MachineSandbox?

    public init(layout: MachineLayout, tuning: Tuning = .standard, sandbox: MachineSandbox? = nil,
                scopedEnvironment: @escaping ScopedEnvironment = { _, base in
                    ScopedProcessEnvironment(values: base, redactions: [])
                },
                observer: (@Sendable ([Status]) async -> Void)? = nil) {
        self.layout = layout
        self.sandbox = sandbox
        self.tuning = tuning
        self.scopedEnvironment = scopedEnvironment
        self.observer = observer
    }

    /// Tells the observer, once per change rather than once per event, and in order.
    ///
    /// Chained rather than spawned loose, because two changes a millisecond apart delivered the
    /// wrong way round would leave a client holding the older one for ever: the reader replaces its
    /// copy, so the last to arrive wins whatever it says.
    private var announcing: Task<Void, Never>?

    private func announce() {
        let current = status
        guard current != announced else { return }
        announced = current
        guard let observer else { return }
        let previous = announcing
        announcing = Task { [current] in
            await previous?.value
            await observer(current)
        }
    }

    public nonisolated var logDirectory: String { layout.dataDirectory + "/services" }

    /// The end of a service's own log, for reading why it exited. Bounded because this is on the
    /// path of a service restarting every second.
    private func tail(of name: String, limit: Int = 4_000) -> String {
        guard let text = try? String(contentsOfFile: logPath(for: name), encoding: .utf8) else { return "" }
        return String(text.suffix(limit))
    }

    /// The sentence for a service that could not have the port it asked for, when the port is one
    /// of ours.
    ///
    /// **A project cannot be expected to know which ports a machine has taken, and until now the
    /// machine never said.** `there-there.app` asked for 8081, which is Bloom Runner's own port,
    /// and the whole of what anybody was told was `Address already in use` in a service log behind
    /// a preview that could not be reached, restarting every second. The collision is the project's
    /// to fix; **being told is ours**.
    ///
    /// Matched on the message the operating system produces rather than on anything a program
    /// chooses, so PHP, node and Python all reach it. A port that is not one of ours gets nothing:
    /// two of a project's own services fighting over a port is not a thing Bloom knows about.
    static func portAdvice(in output: String, reserved: [(port: Int, holder: String)]) -> String? {
        let lower = output.lowercased()
        guard lower.contains("address already in use") else { return nil }
        guard let taken = reserved.first(where: { lower.contains(":\($0.port)") }) else { return nil }
        let list = reserved.map { "\($0.port) (\($0.holder))" }.joined(separator: " and ")
        return "It asked for port \(taken.port), which is \(taken.holder). This machine keeps "
            + "\(list), and names them in BLOOM_RESERVED_PORTS. Serve on $BLOOM_APP_PORT, which is "
            + "what the preview reads, or on any other free port."
    }

    public nonisolated func logPath(for name: String) -> String {
        logDirectory + "/" + Self.fileName(name) + ".log"
    }

    public var status: [Status] {
        order.compactMap { entries[$0] }.map {
            Status(name: $0.service.name, state: $0.state, restarts: $0.restarts, message: $0.message,
                   isHTTP: $0.service.http)
        }
    }

    /// Starts these services, stopping whatever was running first. A service with no valid id, or
    /// a second one under an id already taken, is left out; `RemoteProjectSettings.problems` has
    /// already said so.
    public func start(_ services: [RemoteProjectSettings.Service], environment: [String: String]) async {
        await serially { await self.startNow(services, environment: environment) }
    }

    /// Everything stopped and started again with this environment, which is what a changed team or
    /// project environment needs: a running process cannot be handed new variables.
    public func restartAll(environment: [String: String]) async {
        // The services as they are when this one's turn comes, not when it was asked for.
        await serially { await self.startNow(await self.services, environment: environment) }
    }

    public func stopAll() async {
        await serially { await self.stopNow() }
    }

    /// Starts and stops one after the other. Each suspends while processes stop, and a second one
    /// running in that gap found nothing to stop, launched everything, and was then overwritten by
    /// the first: two copies of every service fighting for its port, one of which nothing could
    /// stop any more.
    private func serially(_ work: @escaping @Sendable () async -> Void) async {
        let previous = operation
        let next = Task {
            await previous?.value
            await work()
        }
        operation = next
        await next.value
    }

    private func startNow(_ services: [RemoteProjectSettings.Service], environment: [String: String]) async {
        await stopNow()
        generation += 1
        self.services = services
        self.environment = environment
        entries = [:]
        order = []
        for service in services where RemoteProjectSettings.validServiceID(service.id) && entries[service.id] == nil {
            entries[service.id] = Entry(service: service)
            order.append(service.id)
        }
        launchWhatIsReady()
    }

    private func stopNow() async {
        generation += 1
        var stopping: [SupervisedProcess] = []
        for id in order {
            guard var entry = entries[id] else { continue }
            entry.readiness?.cancel()
            entry.readiness = nil
            if let process = entry.process { stopping.append(process) }
            entry.process = nil
            entry.up = false
            entry.state = .stopped
            entry.message = nil
            entries[id] = entry
        }
        // All at once, because each can take the whole grace period and ten services one after the
        // other would hold a machine that runbloom.app asked to stop for over a minute.
        await withTaskGroup(of: Void.self) { group in
            for process in stopping {
                group.addTask { await process.stop() }
            }
        }
        announce()
    }

    private func launchWhatIsReady() {
        for id in order {
            guard var entry = entries[id], entry.state == .waiting, entry.process == nil else { continue }
            let missing = entry.service.dependsOn.filter { entries[$0]?.up != true }
            guard missing.isEmpty else {
                entry.message = "Waiting for \(missing.joined(separator: ", "))."
                entries[id] = entry
                continue
            }
            let generation = generation
            let service = entry.service
            let baseEnvironment = environment
            let scopedEnvironment = scopedEnvironment
            let sandbox = sandbox
            let workingDirectory = layout.worktree
            let process = SupervisedProcess(
                command: {
                    let scoped = try await scopedEnvironment(id, baseEnvironment)
                    let command = sandbox.map {
                        $0.wrap(executable: "/bin/sh", arguments: ["-c", service.command], path: scoped.values["PATH"])
                    }
                        ?? (executable: "/bin/sh", arguments: ["-c", service.command])
                    return .init(
                        executable: command.executable,
                        arguments: command.arguments,
                        workingDirectory: workingDirectory,
                        environment: sandbox.map { $0.environment(scoped.values) } ?? scoped.values,
                        redactions: scoped.redactions
                    )
                },
                logPath: logPath(for: id), logLimit: tuning.logLimit, backoff: tuning.backoff, stopGrace: tuning.stopGrace
            ) { [weak self] event in
                await self?.handle(event, service: id, generation: generation)
            }
            entry.process = process
            entry.state = .starting
            entry.message = nil
            entries[id] = entry
            process.start()
        }
        announce()
    }

    private func handle(_ event: SupervisedProcess.Event, service name: String, generation: Int) {
        guard generation == self.generation, var entry = entries[name] else { return }
        entry.readiness?.cancel()
        entry.readiness = nil
        switch event {
        case .launched:
            if let ready = entry.service.ready, let url = ServiceReadiness.url(for: ready, appPort: layout.appPort) {
                entry.state = .starting
                entry.message = "Waiting for \(url) to answer."
                let tuning = tuning
                entry.readiness = Task { [weak self] in
                    let answered = await ServiceReadiness.wait(for: url, deadline: tuning.readinessDeadline, interval: tuning.readinessInterval)
                    guard !Task.isCancelled else { return }
                    await self?.readinessFinished(service: name, generation: generation, answered: answered, url: url)
                }
            } else {
                entry.state = .running
                entry.message = nil
                entry.up = true
            }
        case .exited(let status, let delay):
            entry.state = .crashed
            entry.restarts += 1
            entry.message = "Exited with status \(status). Starting again in \(SupervisedProcess.describe(delay))."
            if let advice = Self.portAdvice(in: tail(of: name), reserved: layout.reservedPorts) {
                entry.message = (entry.message ?? "") + " " + advice
                // Once, rather than once a second for the rest of the machine's life: a service
                // that cannot have its port will say this on every restart, and the point is to be
                // read by somebody, which one line achieves and three thousand do not.
                if !entry.saidAboutPorts {
                    entry.saidAboutPorts = true
                    FileHandle.standardError.write(Data("bloom-runner: \(name): \(advice)\n".utf8))
                }
            }
        case .launchFailed(let delay):
            entry.state = .crashed
            entry.restarts += 1
            entry.message = "Its scoped environment was unavailable. Starting again in \(SupervisedProcess.describe(delay))."
        }
        entries[name] = entry
        announce()
        launchWhatIsReady()
    }

    private func readinessFinished(service name: String, generation: Int, answered: Bool, url: String) {
        guard generation == self.generation, var entry = entries[name], entry.state == .starting else { return }
        entry.readiness = nil
        if answered {
            entry.state = .running
            entry.message = nil
            entry.up = true
        } else {
            entry.state = .notReady
            entry.message = "Running, but \(url) did not answer within \(SupervisedProcess.describe(tuning.readinessDeadline))."
        }
        entries[name] = entry
        announce()
        launchWhatIsReady()
    }

    /// A service name as a file name: a name is whatever the settings file says, and `../app` is
    /// not a log path.
    static func fileName(_ name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let mapped = String(name.map { allowed.contains($0) ? $0 : "-" })
        return mapped.hasPrefix(".") ? "-" + mapped.dropFirst() : mapped
    }
}
