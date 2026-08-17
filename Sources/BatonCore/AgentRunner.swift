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

/// Supervises one `claude` process for one Baton session.
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
    private var nextSeq: Int?
    private var alive = false
    private var cancelled = false

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
    /// without spawning anything.
    public static func argv(session: Session, resume: String?) -> [String] {
        var arguments = [
            "-p",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--permission-mode", session.permissionMode.cliValue,
            "--model", session.model,
        ]
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
            arguments: Self.argv(session: session, resume: session.agentSessionID),
            cwd: workspacePath,
            environment: Shell.environment()
        )
    }

    // MARK: State

    public var isRunning: Bool { alive }

    public var currentSession: Session { session }

    /// Decoded events for the UI. Nonisolated so a view can start consuming without hopping onto
    /// the actor, which means it must not read actor state: the continuation lives in its own
    /// reference box built at init.
    public nonisolated var events: AsyncStream<AgentEvent> { sink.stream }

    public func setPersistsStreamDeltas(_ value: Bool) {
        persistsStreamDeltas = value
    }

    // MARK: Sending

    /// Write one user turn. Starts the process on first use.
    public func send(_ text: String) async throws {
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

    static func encodeTurn(_ text: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(UserTurn(text: text)), as: UTF8.self)
    }

    private func start() throws {
        guard handle.current == nil else { return }

        cancelled = false
        handle.cancelRequested = false
        stderrTail = []
        let process = makeProcess(launch())
        handle.current = process
        alive = true

        // Touching `lines` is what launches the process, so stderr has to be claimed before it or
        // early diagnostics land nowhere. Both consumers are registered before the fork, so no
        // output can be dropped between launch and the first read.
        let errors = process.errorLines
        let lines = process.lines

        readTask = Task { [weak self] in
            await self?.consume(process, lines: lines)
        }
        stderrTask = Task { [weak self] in
            for await line in errors {
                await self?.appendStderr(line)
            }
        }
    }

    private func consume(_ process: any AgentProcessing, lines: AsyncThrowingStream<String, Error>) async {
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
        await finish(status: status, sawResult: sawResult)
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

        case .result(let result):
            session = session.with {
                $0.inputTokens += result.usage.inputTokens
                $0.outputTokens += result.usage.outputTokens
                $0.costUSD += result.usage.costUSD
                $0.contextTokens = result.usage.contextUsedTokens
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

    private func persist(kind: MessageKind, payload: Data, durationMS: Int? = nil, refID: String? = nil) async {
        let seq = await reserveSeq()
        _ = try? await store.append(Message(
            sessionID: session.id,
            seq: seq,
            kind: kind,
            payload: payload,
            durationMS: durationMS,
            refID: refID
        ))
    }

    /// Sequence numbers continue where the stored transcript left off, so a resumed session does
    /// not restart at zero and reorder itself.
    private func reserveSeq() async -> Int {
        if let seq = nextSeq {
            nextSeq = seq + 1
            return seq
        }
        let stored = (try? await store.nextSeq(sessionID: session.id)) ?? 0
        // Another turn may have initialised the counter while this one awaited the store.
        if let seq = nextSeq {
            nextSeq = seq + 1
            return seq
        }
        nextSeq = stored + 1
        return stored
    }

    private func save(_ session: Session) async {
        _ = try? await store.upsert(session)
    }

    // MARK: Finishing

    private func finish(status: Int32, sawResult: Bool) async {
        alive = false
        handle.current = nil
        killTask?.cancel()
        killTask = nil

        // The last stderr lines are usually the reason the process died, and they can still be in
        // flight when stdout closes. Waiting for that task is what makes the tail complete.
        await stderrTask?.value
        stderrTask = nil

        guard !cancelled, !handle.cancelRequested else {
            markCancelled()
            return
        }

        if status != 0, !sawResult {
            let tail = stderrTail.joined(separator: "\n")
            let message = "The agent exited with status \(status)."
            let payload = (try? JSONEncoder().encode(ProcessFailure(status: Int(status), stderr: tail)))
                ?? Data(#"{"type":"error"}"#.utf8)

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
        let wasRunning = !cancelled
        markCancelled()

        guard wasRunning, let process = handle.current else { return }
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
        handle.cancelRequested = true
        alive = false

        session = session.with {
            $0.state = .cancelled
            $0.updatedAt = Date()
        }
        let snapshot = session
        Task { [store] in _ = try? await store.upsert(snapshot) }
    }

    /// Fire and forget, for a SwiftUI button that cannot await. The intent is recorded and the
    /// SIGTERM goes out synchronously, so a busy actor can neither delay the signal nor let the
    /// exit that follows be mistaken for a crash. The bookkeeping catches up a moment later.
    public nonisolated func cancelNow() {
        handle.cancelRequested = true
        handle.current?.terminate()
        Task { await self.cancel() }
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
    }
}

// MARK: - Boxes

/// Holds the events continuation outside the actor so the `events` accessor can be nonisolated.
/// An `AsyncStream.Continuation` is already thread safe, so there is nothing to guard here.
private final class EventSink: @unchecked Sendable {
    let stream: AsyncStream<AgentEvent>
    private let continuation: AsyncStream<AgentEvent>.Continuation

    init() {
        var captured: AsyncStream<AgentEvent>.Continuation!
        stream = AsyncStream(bufferingPolicy: .unbounded) { captured = $0 }
        continuation = captured
    }

    func yield(_ event: AgentEvent) {
        continuation.yield(event)
    }

    func finish() {
        continuation.finish()
    }
}

/// The live process, reachable without actor isolation so a signal can be sent from anywhere.
/// The lock is only ever held across the pointer swap, never across an await.
private final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: (any AgentProcessing)?
    private var cancelled = false

    var current: (any AgentProcessing)? {
        get { read() }
        set { write(newValue) }
    }

    /// Set before the signal goes out, so the exit it causes is not mistaken for a crash by the
    /// read loop finishing on another thread.
    var cancelRequested: Bool {
        get { readCancelled() }
        set { writeCancelled(newValue) }
    }

    private func read() -> (any AgentProcessing)? {
        lock.lock(); defer { lock.unlock() }
        return process
    }

    private func write(_ value: (any AgentProcessing)?) {
        lock.lock(); process = value; lock.unlock()
    }

    private func readCancelled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    private func writeCancelled(_ value: Bool) {
        lock.lock(); cancelled = value; lock.unlock()
    }
}

// MARK: - Permission modes

public extension PermissionMode {
    /// What `--permission-mode` expects. Baton's names happen to line up with the CLI's today,
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
