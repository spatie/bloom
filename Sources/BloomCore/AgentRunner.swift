import Foundation

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
    public nonisolated let sessionID: String

    private let store: Store
    private let makeProcess: @Sendable (AgentLaunch) -> any AgentProcessing
    private let sink = EventSink()
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
    /// Whether the composer's Fast toggle is on for this session.
    ///
    /// Read from the store rather than passed in, because it is the one composer control with no
    /// column on `Session`: it lives in the key value table under `session.<id>.fastMode`, which
    /// is where the footer writes it. Re-read at the top of every turn, so toggling it takes
    /// effect on the next thing sent rather than on the next launch of the app.
    private var isFastMode = false
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
        makeProcess: @escaping @Sendable (AgentLaunch) -> any AgentProcessing = AgentRunner.spawn
    ) {
        self.workspacePath = workspacePath
        self.sessionID = session.id
        self.session = session
        self.store = store
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

    /// The invocation from PROTOCOL.md. `--verbose` is not optional: the CLI refuses to run
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
    public static func argv(session: Session, resume: String?, isFastMode: Bool = false) -> [String] {
        var arguments = [
            "-p",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--permission-mode", session.permissionMode.cliValue,
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
        if let resume, !resume.isEmpty {
            arguments += ["--resume", resume]
        }
        return arguments
    }

    /// How this runner would spawn right now. Recomputed per start, because the agent session id
    /// only exists after the first run and a restart has to resume rather than begin again.
    public func launch() -> AgentLaunch {
        AgentLaunch(
            executable: Self.executable,
            arguments: Self.argv(session: session, resume: session.agentSessionID, isFastMode: isFastMode),
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
    public nonisolated var events: AsyncStream<AgentEvent> { sink.stream }

    public func setPersistsStreamDeltas(_ value: Bool) {
        persistsStreamDeltas = value
    }

    // MARK: Sending

    /// Write one user turn. Starts the process on first use.
    public func send(_ text: String) async throws {
        try await waitForCancelledRunToExit()
        await refreshFastMode()
        try start()

        let line = try Self.encodeTurn(text)
        handle.current?.writeLine(line)

        await persist(kind: .user, payload: Data(line.utf8))

        session = session.with {
            $0.state = .running
            $0.updatedAt = Date()
        }
        await save(session)
    }

    /// The key the composer's footer writes. Duplicated as a constant rather than imported,
    /// because the core cannot see the view layer and a string this load-bearing should be
    /// findable from both ends: `ComposerControls.fastModeKey` is the other half, and
    /// `fastModeKeyMatchesTheComposer` in the suite pins the two together.
    public static func fastModeKey(sessionID: String) -> String {
        "session.\(sessionID).fastMode"
    }

    /// A setting that cannot be read is not a reason to refuse a turn, so a failure leaves the
    /// flag as it was rather than throwing.
    private func refreshFastMode() async {
        guard let value = try? await store.setting(Self.fastModeKey(sessionID: session.id)) else {
            isFastMode = false
            return
        }
        isFastMode = value == "1"
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

    private func start() throws {
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
            session = session.with {
                $0.inputTokens += result.usage.inputTokens
                $0.outputTokens += result.usage.outputTokens
                $0.costUSD += result.usage.costUSD
                // Whatever the last assistant event said, and the previous reading when this turn
                // produced no assistant event at all, which is what an error or a cancellation
                // looks like. Never `result.usage`, which counts the whole turn rather than the
                // window; see `lastContextUsed`.
                if lastContextUsed > 0 { $0.contextTokens = lastContextUsed }
                // A cancelled turn also comes back as an error result, because SIGTERM makes the
                // CLI report error_during_execution on its way out. That is the user pressing
                // stop, not a failure, so cancellation wins over what the result says.
                $0.state = cancelled ? .cancelled : (result.isError ? .failed : .idle)
                $0.updatedAt = Date()
            }
            await save(session)

        default:
            break
        }

        sink.yield(event)
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

        let payload = (try? JSONEncoder().encode(StorageFailure(message: message)))
            ?? Data(#"{"type":"error","subtype":"storage"}"#.utf8)
        sink.yield(.error(AgentError(message: message, raw: payload)))
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

            session = session.with {
                $0.state = .failed
                $0.updatedAt = Date()
            }
            await save(session)
        } else if session.state == .running {
            session = session.with {
                $0.state = .idle
                $0.updatedAt = Date()
            }
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

        session = session.with {
            $0.state = .cancelled
            $0.updatedAt = Date()
        }
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
        if request.accepted { request.process?.terminate() }
        Task { await self.cancel(generation: generation) }
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

    /// The payload of the `.error` event a failed write emits. It never reaches the database, for
    /// the obvious reason, so it only ever exists in flight.
    private struct StorageFailure: Encodable {
        let type = "error"
        let subtype = "storage"
        let message: String
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

/// Fans the runner's events out to every subscriber, outside the actor so the `events` accessor
/// can stay nonisolated.
///
/// One shared `AsyncStream` cannot do this job. A stream is finished by its consumer going away,
/// so the first view to cancel its iteration (pressing Stop does exactly that) took the only
/// channel the session had with it, and every later event was yielded into nothing. Each
/// subscriber gets its own stream and its own continuation instead, registered on access and
/// dropped again by `onTermination`, so one consumer leaving is invisible to the rest.
private final class EventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [Int: AsyncStream<AgentEvent>.Continuation] = [:]
    private var nextToken = 0
    private var closed = false

    var stream: AsyncStream<AgentEvent> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            guard let token = register(continuation) else {
                continuation.finish()
                return
            }
            continuation.onTermination = { [weak self] _ in
                self?.unregister(token)
            }
        }
    }

    func yield(_ event: AgentEvent) {
        for continuation in subscribers() { continuation.yield(event) }
    }

    func finish() {
        for continuation in removeAll() { continuation.finish() }
    }

    // The lock is only ever held across a dictionary access. Yielding happens after it is
    // released, because a continuation can run arbitrary code and must never do so under a lock.

    private func register(_ continuation: AsyncStream<AgentEvent>.Continuation) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return nil }
        nextToken += 1
        continuations[nextToken] = continuation
        return nextToken
    }

    private func unregister(_ token: Int) {
        lock.lock(); continuations[token] = nil; lock.unlock()
    }

    private func subscribers() -> [AsyncStream<AgentEvent>.Continuation] {
        lock.lock(); defer { lock.unlock() }
        return Array(continuations.values)
    }

    private func removeAll() -> [AsyncStream<AgentEvent>.Continuation] {
        lock.lock(); defer { lock.unlock() }
        closed = true
        let all = Array(continuations.values)
        continuations = [:]
        return all
    }
}

/// The live process, reachable without actor isolation so a signal can be sent from anywhere.
/// The lock is only ever held across the pointer swap, never across an await.
private final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: (any AgentProcessing)?
    private var cancelled = false
    private var run = 0

    var current: (any AgentProcessing)? { read() }

    /// Which run this handle is on. Stop is pressed against a particular run, and by the time the
    /// intent reaches the actor the user may already have started the next one, so everything that
    /// acts on a cancellation carries the generation it was meant for.
    var generation: Int { readGeneration() }

    /// Take ownership of a new process. Bumping the generation and clearing the previous run's
    /// cancel intent happen inside the same lock as the swap, so a cancel racing a start either
    /// belongs to the run that just ended, or to this one. It can never straddle both.
    func beginRun(_ process: any AgentProcessing) -> Int {
        lock.lock(); defer { lock.unlock() }
        run += 1
        cancelled = false
        self.process = process
        return run
    }

    /// Let go of the process for a run that has exited.
    func endRun(_ generation: Int) {
        lock.lock(); defer { lock.unlock() }
        guard generation == run else { return }
        process = nil
    }

    func isCancelled(_ generation: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == run && cancelled
    }

    /// Whether the current run has been cancelled and its process has not been let go of yet.
    ///
    /// One lock rather than three separate reads of `current`, `generation` and `cancelled`: a
    /// run can end between any two of them, and the answer assembled from three moments describes
    /// no moment at all.
    var isCancelledRunStillAlive: Bool {
        lock.lock(); defer { lock.unlock() }
        return process != nil && cancelled
    }

    /// Record the intent and hand back the process to signal, in one lock, so a signal can never
    /// end up going to a process from a later run. `accepted` is false when the generation is
    /// stale or the run was already cancelled.
    func requestCancel(_ generation: Int) -> (accepted: Bool, process: (any AgentProcessing)?) {
        lock.lock(); defer { lock.unlock() }
        guard generation == run else { return (false, nil) }
        let accepted = !cancelled
        cancelled = true
        return (accepted, process)
    }

    private func read() -> (any AgentProcessing)? {
        lock.lock(); defer { lock.unlock() }
        return process
    }

    private func readGeneration() -> Int {
        lock.lock(); defer { lock.unlock() }
        return run
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
