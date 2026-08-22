import Foundation
import Synchronization

// MARK: - Process seam

/// What `AgentRunner` needs from a subprocess. `StreamingProcess` is the only production
/// implementation. It is a protocol so tests can drive the runner without launching the real
/// `claude` binary, which would need a network, an account, and money.
public protocol AgentProcessing: Sendable {
    var lines: AsyncThrowingStream<String, Error> { get }
    var errorLines: AsyncStream<String> { get }
    var isRunning: Bool { get }
    var exitStatus: Int32 { get async }

    func writeLine(_ text: String)
    func closeStdin()
    func terminate()
    func kill()
}

extension StreamingProcess: AgentProcessing {}

/// Everything needed to spawn the agent, as a value, so argv can be asserted on without a process
/// ever existing.
public struct AgentLaunch: Sendable, Hashable {
    public let executable: String
    public let arguments: [String]
    public let cwd: String
    public let environment: [String: String]

    public init(executable: String, arguments: [String], cwd: String, environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.cwd = cwd
        self.environment = environment
    }
}

// MARK: - AgentRunner

/// Supervises one `claude` process for one Bloom session.
///
/// The process is long lived: stdin stays open so a follow-up turn is just one more line, and the
/// agent session id from the first `system/init` is persisted the moment it arrives so a crashed
/// app can come back with `--resume`. Every event is written to the store before it reaches the
/// UI, so the transcript is whatever survived a power cut rather than whatever a view happened to
/// be holding.
public actor AgentRunner {
    public nonisolated let workspacePath: String
    public nonisolated let sessionID: SessionID

    private let store: Store
    private let makeProcess: @Sendable (AgentLaunch) -> any AgentProcessing
    private let sink = EventFanout<AgentEvent>()
    /// Held outside the actor so `cancelNow()` can signal a process from synchronous main-actor
    /// code without waiting for a turn on the actor, which is exactly when it is least available.
    private let handle = ProcessHandle()

    private var session: Session
    private var readTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var killTask: Task<Void, Never>?
    private var stderrTail: [String] = []
    /// Which binary this run actually launched, resolved through the same PATH the child got.
    ///
    /// Recorded because "claude" is a name and a machine can hold several. One did: a stale npm
    /// global on Homebrew's PATH and a current native install in `~/.local/bin`, and Bloom
    /// launched from Finder resolved the first while the same user's terminal resolved the
    /// second. The row that reported the crash could not say which one had crashed.
    private var launchedCommand = ""
    /// The per-session MCP config naming the workspace bridge, or nil when there is no bridge to
    /// register. Written once, by whoever built this runner, and read on every process start.
    ///
    /// A runner is built once per session per launch of the app, and the token inside that file is
    /// minted per launch too, so the two have the same lifetime: a session resumed days later is a
    /// new runner with a new file and a new token, which is exactly what a token held only in
    /// memory needs.
    private let mcpConfigPath: String?
    /// Whether the composer's Fast toggle is on for this session.
    ///
    /// Read from the store rather than passed in, because it is the one composer control with no
    /// column on `Session`: it lives in the key value table under `session.<id>.fastMode`, which
    /// is where the footer writes it. Re-read at the top of every turn, so toggling it takes
    /// effect on the next thing sent rather than on the next launch of the app.
    private var isFastMode = false
    /// Which output style the composer's picker is on for this session, or nil for the default.
    ///
    /// Kept beside fast mode and read the same way, because it is the same kind of thing: a
    /// composer control with no column on `Session`, living in the key value table under
    /// `session.<id>.outputStyle`. Nil rather than the word `default`, so "nothing chosen" and
    /// "chosen and then cleared" cannot drift apart on the way to argv.
    private var outputStyle: String?
    /// Questions this process is currently blocked on, newest last.
    ///
    /// Held here as well as in the database because the two are needed at different moments. The
    /// table is what survives a quit; this is what `cancel` can read without awaiting the actor,
    /// which is the one moment the actor is least available and the one moment a pending ask
    /// absolutely has to be answered.
    private let pending = PendingAsks()
    private var cachedRepoID: RepoID?
    private var alive = false
    private var cancelled = false
    private var persistenceFailures = 0
    private var lastFailure: String?

    /// What the model was last handed, from the newest `assistant` event of this turn.
    ///
    /// Tracked as the turn runs because the number is not on the line that closes it. The `usage`
    /// on `result` is the SUM over every API call the turn made, so a turn with ten tool calls
    /// reports roughly ten times the context it actually had: one real session recorded 619k
    /// against a window of 1M where the true figure was 60k. What an `assistant` event carries is
    /// the single call that produced it, which is exactly the context that was in front of the
    /// model. `ContextWindowUsage` reads the same number out of a loaded transcript.
    ///
    /// Rows from inside a subagent are skipped: the Agent tool runs its own conversation with its
    /// own window, and its usage says nothing about this one.
    private var lastContextUsed = 0

    /// Stream deltas are the same text arriving character by character, already superseded by the
    /// `assistant` event behind them. Storing them would multiply the row count and duplicate the
    /// transcript, so they reach the UI live and are then dropped. Flip this on to keep them.
    private var persistsStreamDeltas = false

    /// stderr only ever surfaces when the process dies without a `result`, so a short tail is all
    /// that is worth holding.
    private static let stderrTailLimit = 40

    public init(
        workspacePath: String,
        session: Session,
        store: Store,
        mcpConfigPath: String? = nil,
        makeProcess: @escaping @Sendable (AgentLaunch) -> any AgentProcessing = AgentRunner.spawn
    ) {
        self.workspacePath = workspacePath
        self.sessionID = session.id
        self.session = session
        self.store = store
        self.mcpConfigPath = mcpConfigPath
        self.makeProcess = makeProcess
    }

    /// The default factory. Separate so an injected one can replace it wholesale.
    public static let spawn: @Sendable (AgentLaunch) -> any AgentProcessing = { launch in
        StreamingProcess(
            executable: launch.executable,
            arguments: launch.arguments,
            cwd: launch.cwd,
            environment: launch.environment,
            mergeStderr: false
        )
    }

    // MARK: Argv

    public static let executable = "claude"

    /// The invocation from docs/PROTOCOL.md. `--verbose` is not optional: the CLI refuses to run
    /// `-p --output-format stream-json` without it. Pure and static so it can be asserted on
    /// without spawning anything, which is what `AgentRunnerArgvTests` does: every flag the
    /// composer can set has to be visible in this array, or the control that sets it is decoration.
    ///
    /// `--effort` was missing from here for as long as the composer has offered the picker, so
    /// every reasoning level anyone chose was written to the session row and stopped there.
    /// Verified against the installed CLI rather than assumed: the option is real but hidden from
    /// `--help`'s own summary, it takes `low, medium, high, xhigh, max`, which is exactly the five
    /// the composer offers, and it also accepts `med` as an alias for `medium`.
    ///
    /// An effort Bloom does not know about is passed through rather than filtered. Effort is an
    /// open set here for the same reason the model is: a repository's settings file can pin one,
    /// and `ComposerOption.adding` exists because that has already happened with a model id. The
    /// CLI's own parser is forgiving in exactly the right way, and this was checked by running it:
    /// an unrecognised value prints "Warning: Unknown --effort value ... ignoring it and using the
    /// default effort" on stderr and carries on with exit 0. So a stale or exotic value costs a
    /// warning, never a failed turn, and filtering here would silently replace a level the
    /// repository asked for with one it did not.
    ///
    /// `--thinking` is what fast mode is. It is hidden from `--help` too, and its three values are
    /// `enabled`, `adaptive` and `disabled`. Unlike `--effort` this one is strict: an unrecognised
    /// value exits 1 before the turn starts, which is why only the literal below is ever sent and
    /// why nothing user-supplied may reach it.
    ///
    /// The output style is the odd one out, because **there is no flag for it**. It is a settings
    /// key, `outputStyle`, and the only way to state one for a single run without writing to a
    /// file somebody else owns is `--settings`, which takes a path *or* a JSON string. So a chosen
    /// style is sent as a one key object. Checked by running it: the CLI accepts the object and
    /// starts, and it echoes what it resolved back in `output_style` on the `system/init` line,
    /// which `AgentInit` already reads.
    ///
    /// `--settings` is passed here and nowhere else, and it takes one value rather than
    /// accumulating: a second `--settings` would replace the first rather than merge with it, and
    /// a malformed string is read as a filename and exits 1 with "Settings file not found". So the
    /// object is built by `JSONSerialization` rather than by interpolation, and anything else that
    /// ever needs a setting has to be added to that object rather than to a second flag.
    ///
    /// `mcpConfigPath` is the workspace bridge, registered per process start. A **file**, never
    /// the inline JSON string the same flag also accepts, because argv is visible in `ps` and an
    /// agent runs `ps` through its own Bash tool as ordinary behaviour. And never
    /// `--strict-mcp-config` beside it: that flag shuts every other MCP configuration out, which
    /// is right for `WorkspaceNamer` and wrong for a chat, where the user's own servers have to
    /// survive. See `BridgeRegistration`.
    public static func argv(
        session: Session,
        resume: String?,
        isFastMode: Bool = false,
        outputStyle: String? = nil,
        mcpConfigPath: String? = nil
    ) -> [String] {
        var arguments = [
            "-p",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--permission-mode", session.permissionMode.cliValue,
            // Always on, and this is the argument for it. Without it the CLI answers permission
            // questions on the user's behalf and the answer is no, which is every `permission-rule`
            // refusal in every transcript. With it the CLI stops deciding and asks.
            //
            // It does not make the CLI ask more. The classifier still approves everything it
            // approved before: measured over one ordinary turn under `acceptEdits` doing a file
            // read, `ls -la`, `git status`, a write, an edit, `wc -l` and a piped `curl`, the count
            // was zero questions for seven tool calls. The only calls that reach this wire are the
            // ones that are refused today, so the flag changes the answer in exactly the cases
            // where the current answer is "no" and nobody was asked.
            //
            // That is also why it is not tied to the permission mode picker. The picker still
            // means what it meant; this only decides who answers when the mode has escalated, and
            // making it a setting would be offering to go back to being refused silently.
            //
            // Undocumented: absent from `--help`, present in the binary, and the value the
            // official TypeScript SDK passes whenever a `canUseTool` callback is supplied.
            "--permission-prompt-tool", "stdio",
            // Translated, because a model id can come from a Conductor settings file and the
            // CLI does not accept Conductor's names. See `ModelAlias`.
            "--model", ModelAlias.cliValue(for: session.model),
        ]
        let effort = session.effort.trimmingCharacters(in: .whitespacesAndNewlines)
        if !effort.isEmpty {
            arguments += ["--effort", effort]
        }
        // "Fast mode trades some reasoning for a quicker reply", which is this and nothing else.
        // Only sent when it is on: leaving the flag off is what lets the model decide, and
        // sending `adaptive` explicitly would override a session default somebody else set.
        if isFastMode {
            arguments += ["--thinking", "disabled"]
        }
        // Only when a style was actually chosen. The default is the absence of the key, not the
        // word "default": sending it would state a setting, and a stated setting outranks one the
        // repository put in its own `.claude/settings.json`. Leaving the picker alone must not
        // quietly switch off a style the project set for itself.
        if let settings = settingsJSON(outputStyle: outputStyle) {
            arguments += ["--settings", settings]
        }
        if let mcpConfigPath, !mcpConfigPath.isEmpty {
            arguments += BridgeRegistration.claudeArguments(configPath: mcpConfigPath)
        }
        if let resume, !resume.isEmpty {
            arguments += ["--resume", resume]
        }
        return arguments
    }

    /// The `--settings` object for a chosen output style, or nothing at all for the default.
    ///
    /// Built rather than written out, because a custom style is named by a file somebody else
    /// created and a name holding a quote would otherwise produce a string the CLI reads as a
    /// path. Serialisation cannot fail for a dictionary of two strings, but the failure is handled
    /// as "send nothing" anyway: a turn that runs unstyled is better than one that does not run.
    public static func settingsJSON(outputStyle: String?) -> String? {
        guard let outputStyle, !OutputStyle.isDefault(outputStyle) else { return nil }
        let object = ["outputStyle": outputStyle.trimmingCharacters(in: .whitespacesAndNewlines)]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// How this runner would spawn right now. Recomputed per start, because the agent session id
    /// only exists after the first run and a restart has to resume rather than begin again.
    public func launch() -> AgentLaunch {
        AgentLaunch(
            executable: Self.executable,
            arguments: Self.argv(
                session: session,
                resume: session.agentSessionID,
                isFastMode: isFastMode,
                outputStyle: outputStyle,
                mcpConfigPath: mcpConfigPath
            ),
            cwd: workspacePath,
            environment: Shell.environment()
        )
    }

    // MARK: State

    public var isRunning: Bool { alive }

    public var currentSession: Session { session }

    /// The last thing that could not be written to disk, kept for as long as the runner lives.
    /// A transcript that only exists on screen is worth saying out loud, and an `.error` event
    /// scrolls away.
    public var lastPersistenceFailure: String? { lastFailure }

    /// How many rows never made it to the store.
    public var persistenceFailureCount: Int { persistenceFailures }

    /// Decoded events for the UI. Nonisolated so a view can start consuming without hopping onto
    /// the actor, which means it must not read actor state: the sink lives in its own reference
    /// box built at init.
    ///
    /// Every access hands back a **new** stream. One shared stream made the first consumer to walk
    /// away take the session with it: cancelling the task that iterates an `AsyncStream` finishes
    /// that stream for good, so pressing Stop once left the UI staring at a runner that was still
    /// working and still writing rows nobody would ever see.
    public nonisolated var events: AsyncStream<AgentEvent> { sink.stream() }

    public func setPersistsStreamDeltas(_ value: Bool) {
        persistsStreamDeltas = value
    }

    // MARK: Sending

    /// Write one user turn. Starts the process on first use.
    public func send(_ text: String) async throws {
        try await waitForCancelledRunToExit()
        await refreshFastMode()
        await refreshOutputStyle()
        start()

        let line = try Self.encodeTurn(text)
        handle.current?.writeLine(line)

        await persist(kind: .user, payload: Data(line.utf8))

        session.apply(.turnStarted)
        await save(session)
    }

    /// A setting that cannot be read is not a reason to refuse a turn, so a failure leaves the
    /// flag as it was rather than throwing.
    ///
    /// The key is `ComposerControls`'s own, not a copy of it. Both ends used to state the string
    /// and a test in the suite pinned them together, because the core could not see the view layer
    /// where the footer lived. `ComposerControls` is in the core now, so there is one string and
    /// nothing left to drift.
    private func refreshFastMode() async {
        guard let value = try? await store.setting(ComposerControls.fastModeKey(sessionID: session.id)) else {
            isFastMode = false
            return
        }
        isFastMode = value == "1"
    }

    /// A setting that cannot be read leaves the session unstyled rather than refusing the turn.
    /// Reading `default` back is the same as reading nothing, because the picker stores the word
    /// and the wire wants the absence. Same key and the same bargain as fast mode above.
    private func refreshOutputStyle() async {
        let stored = try? await store.setting(ComposerControls.outputStyleKey(sessionID: session.id))
        outputStyle = OutputStyle.isDefault(stored) ? nil : stored
    }

    static func encodeTurn(_ text: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(UserTurn(text: text)), as: UTF8.self)
    }

    /// A cancelled process is still dying for up to three seconds, because SIGTERM comes first and
    /// SIGKILL only follows if it was ignored. Writing the next turn into that process hands the
    /// user's text to something on its way out, so the turn waits for the exit instead. Waiting on
    /// the actor is safe: `finish` runs on it too and every sleep here is a suspension point.
    private func waitForCancelledRunToExit() async throws {
        guard handle.isCancelledRunStillAlive else { return }

        for _ in 0..<Self.shutdownPolls {
            try? await Task.sleep(for: Self.shutdownPollInterval)
            if handle.current == nil { return }
        }
        throw AgentRunnerError.previousRunStillExiting
    }

    /// Long enough to cover SIGTERM, the three second grace period, and the SIGKILL behind it.
    private static let shutdownPolls = 200
    private static let shutdownPollInterval = Duration.milliseconds(25)

    private func start() {
        guard handle.current == nil else { return }

        cancelled = false
        stderrTail = []
        let spec = launch()
        launchedCommand = Shell.which(spec.executable) ?? spec.executable
        let process = makeProcess(spec)
        // Taking the process and bumping the run generation is one step, so a cancel racing this
        // either belongs to the run that just ended (and is dropped) or to this one.
        let generation = handle.beginRun(process)
        alive = true

        // Touching `lines` is what launches the process, so stderr has to be claimed before it or
        // early diagnostics land nowhere. Both consumers are registered before the fork, so no
        // output can be dropped between launch and the first read.
        let errors = process.errorLines
        let lines = process.lines

        readTask = Task { [weak self] in
            await self?.consume(process, lines: lines, generation: generation)
        }
        stderrTask = Task { [weak self] in
            for await line in errors {
                await self?.appendStderr(line)
            }
        }
    }

    private func consume(
        _ process: any AgentProcessing,
        lines: AsyncThrowingStream<String, Error>,
        generation: Int
    ) async {
        var sawResult = false
        do {
            for try await line in lines {
                guard let event = AgentEvent.decode(line: line) else { continue }
                if case .result = event { sawResult = true }
                await ingest(event)
            }
        } catch {
            appendStderr("\(error)")
        }

        let status = await process.exitStatus
        await finish(status: status, sawResult: sawResult, generation: generation)
    }

    private func appendStderr(_ line: String) {
        stderrTail.append(line)
        if stderrTail.count > Self.stderrTailLimit {
            stderrTail.removeFirst(stderrTail.count - Self.stderrTailLimit)
        }
    }

    // MARK: Ingest

    /// Persist one event, apply whatever it says about the session, then hand it to the UI.
    /// Internal rather than private so tests can exercise persistence without a process.
    func ingest(_ event: AgentEvent) async {
        if event.isTranscriptRow || persistsStreamDeltas {
            var durationMS: Int?
            if case .result(let result) = event { durationMS = result.durationMS }
            await persist(kind: event.kind, payload: event.raw, durationMS: durationMS, refID: event.refID)
        }

        switch event {
        case .initialized(let info):
            if !info.sessionID.isEmpty, session.agentSessionID != info.sessionID {
                session = session.with {
                    $0.agentSessionID = info.sessionID
                    $0.updatedAt = Date()
                }
                await save(session)
            }

        case .assistantText(let block), .thinking(let block):
            guard block.parentToolUseID == nil, block.usage.contextUsedTokens > 0 else { break }
            lastContextUsed = block.usage.contextUsedTokens

        case .result(let result):
            // A cancelled turn also comes back as an error result, because SIGTERM makes the CLI
            // report error_during_execution on its way out. That is the user pressing stop, not a
            // failure. This used to be a `cancelled ? .cancelled : ...` ternary here and another
            // one in `CodexRunner`; `SessionLifecycle` says it once instead, by making
            // `turnFinished` change nothing on a session that has already been stopped.
            session.apply(.turnFinished(isError: result.isError))
            session = session.with {
                $0.inputTokens += result.usage.inputTokens
                $0.outputTokens += result.usage.outputTokens
                $0.costUSD += result.usage.costUSD
                // Whatever the last assistant event said, and the previous reading when this turn
                // produced no assistant event at all, which is what an error or a cancellation
                // looks like. Never `result.usage`, which counts the whole turn rather than the
                // window; see `lastContextUsed`.
                if lastContextUsed > 0 { $0.contextTokens = lastContextUsed }
            }
            await save(session)

        default:
            break
        }

        sink.yield(event)

        // After the yield, deliberately. A question a stored rule answers is decided in the same
        // breath it arrives, and `.permissionDecided` reaching a view before the `.permissionAsk`
        // it decides means the view has no row to settle: it drops the decision on the floor and
        // then draws an answered question with four live buttons under it. Measured against the
        // real CLI, which is how it was found.
        if case .permissionAsk(let ask) = event {
            await handle(ask)
        }
    }

    /// Write one row.
    ///
    /// The sequence number is allocated by the store, in the same call and the same transaction as
    /// the insert, so two writers can never both reserve it. That is also why a failed write
    /// advances nothing: the number was never handed out.
    private func persist(kind: MessageKind, payload: Data, durationMS: Int? = nil, refID: String? = nil) async {
        do {
            try await store.appendNext(
                sessionID: session.id,
                kind: kind,
                payload: payload,
                durationMS: durationMS,
                refID: refID
            )
        } catch {
            report("Could not store a \(kind.rawValue) row", error)
        }
    }

    /// Writes the columns this runner owns, and nothing else.
    ///
    /// The distinction is not cosmetic here. This runner holds one `Session` value for as long as
    /// the workspace is open, mutating it in place turn after turn, so every column it did not
    /// write is a copy of how that column looked when the workspace was opened. Saving the whole
    /// value put all of them back: a session renamed mid turn got its old name again, a model or
    /// a permission mode picked in the composer was reverted, a tab closed while the agent was
    /// working reopened, and the read mark came undone.
    ///
    /// And `agent_session_id` runs the other way. It is written here, from `system/init`, and it
    /// is what `--resume` is built from, so a whole-value write from the UI's copy erased it and
    /// the conversation could not be continued. `TranscriptModel.refreshSession` says the same
    /// rule from the other side: what this runner owns only ever travels in that direction.
    ///
    /// `updatedAt` is included because it is this runner's statement about when the turn moved,
    /// which is what `refreshSession` reads to decide whether a row still describes the last turn.
    ///
    /// `state` is carried rather than decided. Nothing in this runner assigns it: every move goes
    /// through `Session.apply`, so what is mirrored onto the row here is whatever
    /// `SessionLifecycle` allowed, and this line cannot invent a state the table would refuse.
    private func save(_ session: Session) async {
        do {
            try await store.update(sessionID: session.id) {
                $0.agentSessionID = session.agentSessionID
                $0.state = session.state
                $0.inputTokens = session.inputTokens
                $0.outputTokens = session.outputTokens
                $0.costUSD = session.costUSD
                $0.contextTokens = session.contextTokens
                $0.updatedAt = session.updatedAt
            }
        } catch {
            report("Could not save the session", error)
        }
    }

    /// Say so when the store refuses a write.
    ///
    /// These used to be `try?`, and the event went out as though it had been stored: a failing
    /// database threw the whole transcript away and told nobody. The failure now reaches the UI as
    /// an `.error` event and stays readable on the runner afterwards. It goes straight to the sink
    /// rather than through `ingest`, because storing a row is exactly what just failed.
    private func report(_ what: String, _ error: Error) {
        let message = "\(what): \(error)"
        persistenceFailures += 1
        lastFailure = message
        sink.yield(.error(.storage(message: message)))
    }

    // MARK: Permission asks

    /// A question has arrived. Either a rule the user already granted answers it, or it goes on
    /// the pile and the session stops being a session that is working.
    private func handle(_ ask: PermissionAsk) async {
        pending.add(ask)
        do {
            try await store.appendPermissionAsk(sessionID: session.id, ask: ask)
        } catch {
            report("Could not store a permission question", error)
        }

        // Bloom's own bridge tools answer themselves. Checked before the grant lookup because it
        // needs no lookup: there is nothing stored to match and nothing for a person to weigh.
        // See `BridgeToolApproval` for why this is not a shortcut round consent.
        if BridgeToolApproval.isSelfApproved(toolName: ask.toolName), let claimed = pending.take(ask.requestID) {
            await write(answerTo: claimed, decision: .allow(scope: .once))
            await close(claimed, as: PermissionAskOutcome.auto, note: BridgeToolApproval.note)
            return
        }

        // Both awaits below are suspension points on this actor, and the question is already on
        // screen by the time they run, so a person can answer it while the grant lookup is still
        // in flight. `claim` is what stops the two of them both reaching the pipe: whoever gets
        // there first takes the ask out of the pile, and the loser does nothing. Without it the
        // CLI receives two `control_response` lines for one request id and logs the second as a
        // mismatch. Found by running the real thing.
        let grants = await matchingGrants(for: ask)

        if let grants, let claimed = pending.take(ask.requestID) {
            await autoAllow(claimed, using: grants)
            return
        }

        // Answered by a person while the lookup was running. Nothing left to do, and in particular
        // the session must not now be marked as waiting for a question that is already settled.
        guard grants == nil, pending.contains(ask.requestID) else { return }

        // Nothing answers it, so somebody has to. This is the state that has to be visible from
        // outside the workspace: a process that is alive, costing nothing, and doing nothing.
        session.apply(.blocked)
        await save(session)
    }

    /// The project's granted rules, or nil when nothing there covers this ask.
    ///
    /// Read from the store on every ask rather than cached. That is what makes revoking a rule
    /// take effect on the next question instead of on the next launch, and asks are rare enough
    /// that one query each is not worth a cache that could go stale in the wrong direction.
    private func matchingGrants(for ask: PermissionAsk) async -> [PermissionGrant]? {
        guard ask.canWiden, let repoID = await repoID() else { return nil }
        guard let grants = try? await store.permissionGrants(repoID: repoID) else { return nil }
        return PermissionGrantIndex.match(ask: ask, grants: grants)
    }

    /// Answer without troubling anybody, and say in the transcript that that is what happened.
    /// The ask must already have been claimed out of `pending` by the caller.
    private func autoAllow(_ ask: PermissionAsk, using grants: [PermissionGrant]) async {
        // The wire form of project scope: the CLI is told to stop asking for the rest of this
        // session, and nothing is written to any settings file.
        await write(answerTo: ask, decision: .allow(scope: .project))
        await close(ask, as: PermissionAskOutcome.auto, note: PermissionGrantIndex.note(for: grants))

        for grant in grants {
            try? await store.recordPermissionGrantUse(id: grant.id)
        }
    }

    /// Answer one question, as a person. The turn resumes on the other side of this line.
    ///
    /// Not a user turn, which is the whole reason it cannot go through `send`: `send` writes a
    /// `user` message and files a transcript row, and this writes a `control_response` that
    /// unblocks a turn already in flight. The two share only the pipe.
    public func answer(requestID: String, decision: PermissionDecision) async {
        guard let ask = pending.take(requestID) else { return }

        await write(answerTo: ask, decision: decision)
        await close(ask, as: decision.storedName, note: "")

        // Granting is Bloom's own bookkeeping and happens after the CLI has been unblocked, so a
        // database that refuses the write cannot leave an agent hanging on a question that was
        // already answered.
        if let repoID = await repoID() {
            for grant in PermissionGrant.all(granting: decision, from: ask, repoID: repoID) {
                _ = try? await store.upsert(grant)
            }
        }
    }

    /// Put the answer on stdin, and let the session go back to running if nothing else is waiting.
    private func write(answerTo ask: PermissionAsk, decision: PermissionDecision) async {
        guard let line = try? PermissionAnswer.encode(ask: ask, decision: decision) else { return }
        handle.current?.writeLine(line)

        guard pending.isEmpty else { return }
        // `unblocked` on a session that was not waiting is legal and does nothing, so this is one
        // question of the table rather than a state test and a write that have to agree.
        guard session.apply(.unblocked).moves else { return }
        await save(session)
    }

    /// File what was decided and tell the UI, in that order.
    private func close(_ ask: PermissionAsk, as decision: String, note: String) async {
        pending.remove(ask.requestID)
        do {
            try await store.resolvePermissionAsk(id: ask.requestID, decision: decision)
        } catch {
            report("Could not record a permission decision", error)
        }
        sink.yield(.permissionDecided(PermissionResolution(
            requestID: ask.requestID,
            toolUseID: ask.toolUseID,
            decision: decision,
            note: note
        )))
    }

    /// What this session's workspace belongs to. Looked up rather than held, because a runner
    /// outlives any particular view and the answer never changes.
    private func repoID() async -> RepoID? {
        if let cachedRepoID { return cachedRepoID }
        guard let workspace = try? await store.workspace(id: session.workspaceID) else { return nil }
        cachedRepoID = workspace.repoID
        return cachedRepoID
    }

    /// Everything still waiting, so a view can draw the questions without asking the database.
    public var pendingAsks: [PermissionAsk] { pending.all }

    /// Deny every open question in words, before the pipe closes underneath it.
    ///
    /// This is the difference between a turn that ends and a turn that dies. The CLI holds a
    /// blocked turn open until it gets an answer, an abort, or an EOF, and only the first of those
    /// produces a `result` line: closing stdin instead leaves the agent dying against a closed
    /// stream, which is exactly the red exit row this codebase spent three commits making honest.
    ///
    /// Synchronous, and reading the asks from a box rather than from actor state, because the two
    /// callers are Stop and app termination and neither can wait for a busy actor.
    @discardableResult
    public nonisolated func denyPendingAsks(_ message: String) -> [PermissionAsk] {
        guard let process = handle.current else { return [] }
        let denied = pending.drain()
        for ask in denied {
            guard let line = try? PermissionAnswer.encode(
                ask: ask,
                // `interrupt` is what makes the turn end here rather than carry on without the
                // call, which is what both callers mean.
                decision: .deny(message: message, endsTurn: true)
            ) else { continue }
            process.writeLine(line)
        }
        return denied
    }

    /// File the questions `denyPendingAsks` answered on the way out.
    ///
    /// Separate from the writing because the writing has to be synchronous and this cannot be:
    /// without it the pipe is unblocked but the database still lists the questions as pending, so
    /// the launch sweep would report them as abandoned and the rows would keep their live buttons.
    /// On quit the process usually dies before this runs, which is exactly what the sweep is for.
    func recordDenied(_ asks: [PermissionAsk], as outcome: String) async {
        for ask in asks {
            await close(ask, as: outcome, note: "")
        }
    }

    // MARK: Finishing

    private func finish(status: Int32, sawResult: Bool, generation: Int) async {
        // A run that is no longer the current one has nothing left to say about the session.
        guard generation == handle.generation else { return }

        alive = false
        handle.endRun(generation)
        killTask?.cancel()
        killTask = nil

        // The last stderr lines are usually the reason the process died, and they can still be in
        // flight when stdout closes. Waiting for that task is what makes the tail complete.
        //
        // Taken off the actor before the await, so a run that starts during the suspension puts
        // its own task there and does not have it cleared out from under it.
        let stderr = stderrTask
        stderrTask = nil
        await stderr?.value

        // That await is a suspension point, and `send` only needs the handle to be free to start
        // the next turn, which it now is. Everything below writes the session row, so a stale run
        // reaching it would file the turn the user just started as finished.
        guard generation == handle.generation else { return }

        guard !cancelled, !handle.isCancelled(generation) else {
            markCancelled()
            return
        }

        if status != 0, !sawResult {
            let tail = stderrTail.joined(separator: "\n")
            let message = "The agent exited with status \(status)."
            let payload = (try? JSONEncoder().encode(
                ProcessFailure(status: Int(status), stderr: tail, command: launchedCommand)
            )) ?? Data(#"{"type":"error"}"#.utf8)

            await ingest(.error(AgentError(
                message: tail.isEmpty ? message : "\(message)\n\(tail)",
                raw: payload
            )))

            session.apply(.processFailed)
            await save(session)
        } else if session.apply(.processExited).moves {
            // A session left `waiting` moves here too, which the state test this replaced did not
            // do: the pipe is closed, so the question it was blocked on can never be answered.
            await save(session)
        }
    }

    // MARK: Cancelling

    /// SIGTERM now, SIGKILL in three seconds if the agent is still around. Claude Code usually
    /// wants a moment to flush, but it does not get to hang the app.
    public func cancel() {
        cancel(generation: handle.generation)
    }

    /// Cancel one specific run.
    ///
    /// A cancel queued by `cancelNow` reaches the actor whenever the actor gets round to it, which
    /// can be after the user has already started the next turn. Acting on it then would SIGTERM
    /// the turn they just asked for and file the whole thing as a failure, so a cancel that no
    /// longer names the current run is dropped.
    func cancel(generation: Int) {
        guard generation == handle.generation else { return }
        let request = handle.requestCancel(generation)

        let wasCancelled = cancelled
        markCancelled()

        guard !wasCancelled, let process = request.process ?? handle.current else { return }
        // Before the pipe closes, not after. A question left to die against a closed stream ends
        // the turn as a crash instead of as a result.
        let denied = denyPendingAsks(PermissionDecision.stoppedMessage)
        if !denied.isEmpty {
            Task { [weak self] in await self?.recordDenied(denied, as: PermissionAskOutcome.stopped) }
        }
        process.closeStdin()
        process.terminate()

        killTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, process.isRunning else { return }
            process.kill()
        }
    }

    /// Cancellation can be noticed here or by the read loop finishing first, so the bookkeeping
    /// has to be idempotent and cannot live in either path alone.
    private func markCancelled() {
        guard !cancelled else { return }
        cancelled = true
        alive = false

        // Refused on a session with no turn open, and left alone rather than written. Stop is fire
        // and forget from a button that cannot await, so the request reaches this actor whenever
        // the actor gets to it; filing a turn that had already finished normally as one the user
        // abandoned is a claim the transcript then makes for ever.
        session.apply(.cancelled)
        // The write has to be deferred, because this is reached from synchronous paths, but it
        // deliberately does not carry a snapshot: by the time it runs the user may already have
        // started the next turn, and writing a copy taken now would put that turn back to
        // `cancelled`. Saving whatever the session is at that point cannot go backwards.
        Task { [weak self] in await self?.saveCurrentSession() }
    }

    private func saveCurrentSession() async {
        await save(session)
    }

    /// Fire and forget, for a SwiftUI button that cannot await. The intent is recorded and the
    /// SIGTERM goes out synchronously, so a busy actor can neither delay the signal nor let the
    /// exit that follows be mistaken for a crash. The bookkeeping catches up a moment later.
    ///
    /// The run being cancelled is captured here rather than read again later, so the signal and
    /// the bookkeeping both land on the run the user was looking at when they pressed Stop.
    public nonisolated func cancelNow() {
        let generation = handle.generation
        let request = handle.requestCancel(generation)
        // Answer before the signal, not after. `requestCancel` has already marked the run
        // cancelled, so the deny inside `cancel(generation:)` is now unreachable, and `terminate`
        // below closes the stream a blocked turn is waiting on. Doing it in the other order is
        // what the model actually receives: measured against the real CLI, Stop used to hand it
        // "AbortError: Tool permission stream closed" where it now gets a sentence saying the turn
        // was stopped before the question could be answered.
        let denied = denyPendingAsks(PermissionDecision.stoppedMessage)
        if request.accepted { request.process?.terminate() }
        Task { [weak self] in
            if !denied.isEmpty {
                await self?.recordDenied(denied, as: PermissionAskOutcome.stopped)
            }
            await self?.cancel(generation: generation)
        }
    }

    // MARK: Wire formats

    private struct UserTurn: Encodable {
        struct Block: Encodable {
            let type = "text"
            let text: String
        }

        struct Body: Encodable {
            let role = "user"
            let content: [Block]
        }

        let type = "user"
        let message: Body

        init(text: String) {
            message = Body(content: [Block(text: text)])
        }
    }

    /// Stored as the `.error` row when the process dies without ever emitting a `result`.
    private struct ProcessFailure: Encodable {
        let type = "error"
        let subtype = "process_exit"
        let status: Int
        let stderr: String
        /// The resolved path of what was launched, so a row can name the binary that died rather
        /// than the name it was asked for.
        let command: String
    }

}

// MARK: - Errors

public enum AgentRunnerError: Error, Equatable, CustomStringConvertible, Sendable {
    /// A turn was sent while the previous, cancelled process was still shutting down.
    case previousRunStillExiting

    public var description: String {
        switch self {
        case .previousRunStillExiting:
            "The previous agent is still shutting down. Try again in a moment."
        }
    }
}

// MARK: - Boxes

/// The live process, reachable without actor isolation so a signal can be sent from anywhere.
/// The lock is only ever held across the pointer swap, never across an await.
///
/// `Mutex<State>` rather than `NSLock` plus `@unchecked Sendable`, for the reason given on
/// `EventFanout` in `SessionRunner`: the three fields below have to be read together to describe
/// a moment, and putting them in one value the compiler will not let anything reach outside the
/// lock is stronger than a promise that nothing does.
private final class ProcessHandle: Sendable {
    private struct State {
        var process: (any AgentProcessing)?
        var cancelled = false
        var run = 0
    }

    private let state = Mutex(State())

    var current: (any AgentProcessing)? { state.withLock(\.process) }

    /// Which run this handle is on. Stop is pressed against a particular run, and by the time the
    /// intent reaches the actor the user may already have started the next one, so everything that
    /// acts on a cancellation carries the generation it was meant for.
    var generation: Int { state.withLock(\.run) }

    /// Take ownership of a new process. Bumping the generation and clearing the previous run's
    /// cancel intent happen inside the same lock as the swap, so a cancel racing a start either
    /// belongs to the run that just ended, or to this one. It can never straddle both.
    func beginRun(_ process: any AgentProcessing) -> Int {
        state.withLock { state in
            state.run += 1
            state.cancelled = false
            state.process = process
            return state.run
        }
    }

    /// Let go of the process for a run that has exited.
    func endRun(_ generation: Int) {
        state.withLock { state in
            guard generation == state.run else { return }
            state.process = nil
        }
    }

    func isCancelled(_ generation: Int) -> Bool {
        state.withLock { generation == $0.run && $0.cancelled }
    }

    /// Whether the current run has been cancelled and its process has not been let go of yet.
    ///
    /// One lock rather than three separate reads of `current`, `generation` and `cancelled`: a
    /// run can end between any two of them, and the answer assembled from three moments describes
    /// no moment at all.
    var isCancelledRunStillAlive: Bool {
        state.withLock { $0.process != nil && $0.cancelled }
    }

    /// Record the intent and hand back the process to signal, in one lock, so a signal can never
    /// end up going to a process from a later run. `accepted` is false when the generation is
    /// stale or the run was already cancelled.
    func requestCancel(_ generation: Int) -> (accepted: Bool, process: (any AgentProcessing)?) {
        state.withLock { state -> (accepted: Bool, process: (any AgentProcessing)?) in
            guard generation == state.run else { return (false, nil) }
            let accepted = !state.cancelled
            state.cancelled = true
            return (accepted, state.process)
        }
    }
}

// MARK: - Permission modes

public extension PermissionMode {
    /// What `--permission-mode` expects. Bloom's names happen to line up with the CLI's today,
    /// but they are two separate vocabularies and drift is a matter of time.
    var cliValue: String {
        switch self {
        case .auto: "auto"
        case .acceptEdits: "acceptEdits"
        case .bypassPermissions: "bypassPermissions"
        case .plan: "plan"
        }
    }
}


