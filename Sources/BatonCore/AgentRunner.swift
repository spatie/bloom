import Foundation

// MARK: - Process seam

/// What `AgentRunner` needs from a subprocess. `StreamingProcess` is the only production
/// implementation. It exists as a protocol so tests can drive the runner without launching the
/// real `claude` binary, which would cost money and need a network.
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

/// Everything needed to spawn the agent, kept as a value so argv can be asserted on without a
/// process existing.
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
/// The process is long lived: stdin stays open so a follow-up turn is just another line, and the
/// agent session id from the first `system/init` is persisted immediately so a crashed app can
/// come back with `--resume`. Every event is written to the store before it reaches the UI, so
/// the transcript is whatever survived a power cut, not whatever a view happened to hold.
public actor AgentRunner {
    public nonisolated let workspacePath: String
    public nonisolated let sessionID: String

    private let store: Store
    private let makeProcess: @Sendable (AgentLaunch) -> any AgentProcessing
    private let sink = EventSink()

    private var session: Session
    private var process: (any AgentProcessing)?
    private var readTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var killTask: Task<Void, Never>?
    private var stderrTail: [String] = []
    private var nextSeq: Int?
    private var alive = false
    private var cancelled = false

    /// Stream deltas are the same text arriving character by character, already superseded by the
    /// `assistant` event behind them. Persisting them would triple the row count and duplicate
    /// the transcript, so they reach the UI live and are dropped. Flip this on to keep them.
    public var persistsStreamDeltas = false

    /// stderr is only ever surfaced when the process dies without a `result`, so a few lines of
    /// tail is all that is worth holding on to.
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

    /// The default factory. Kept separate so the injected one can be swapped wholesale.
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
    /// `-p --output-format stream-json` without it.
    public static func arguments(for session: Session) -> [String] {
        var arguments = [
            "-p",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--permission-mode", session.permissionMode.cliValue,
            "--model", session.model,
        ]
        if let agentSessionID = session.agentSessionID, !agentSessionID.isEmpty {
            arguments += ["--resume", agentSessionID]
        }
        return arguments
    }

    /// Argv for this runner right now. It is recomputed per start because the agent session id
    /// only exists after the first run, and a restart has to resume rather than begin again.
    public func launch() -> AgentLaunch {
        AgentLaunch(
            executable: Self.executable,
            arguments: Self.arguments(for: session),
            cwd: workspacePath,
            environment: Shell.environment()
        )
    }

    // MARK: State

    public var isRunning: Bool { alive }

    public var currentSession: Session { session }

    /// Decoded events for the UI. Nonisolated so a view can start consuming without hopping onto
    /// the actor, which means it must not read actor state: the continuation lives in its own
    /// reference box created at init.
    public nonisolated var events: AsyncStream<AgentEvent> { sink.stream }

    public func setPersistsStreamDeltas(_ value: Bool) {
        persistsStreamDeltas = value
    }

    // MARK: Sending

    /// Write one user turn. Starts the process on first use.
    public func send(_ text: String) async throws {
        try start()

        let line = try Self.encodeTurn(text)
        process?.writeLine(line)

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
        let data = try encoder.encode(UserTurn(text: text))
        return String(decoding: data, as: UTF8.self)
    }

    private func start() throws {
        guard process == nil else { return }

        cancelled = false
        let proc = makeProcess(launch())
        process = proc
        alive = true

        // Touching `lines` is what starts the process, so stderr has to be claimed before it or
        // early diagnostics land nowhere. Both consumers are registered before launch, so no
        // output can be dropped between the fork and the first read.
        let errors = proc.errorLines
        let lines = proc.lines

        readTask = Task { [weak self] in
            await self?.consume(proc, lines: lines)
        }
        stderrTask = Task { [weak self] in
            for await line in errors {
                await self?.appendStderr(line)
            }
        }
    }

    private func consume(_ proc: any AgentProcessing, lines: AsyncThrowingStream<String, Error>) async {
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

        let status = await proc.exitStatus
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
            if case .result(_, let result) = event { durationMS = result.durationMS }
            await persist(kind: event.kind, payload: event.raw, durationMS: durationMS, refID: event.refID)
        }

        switch event {
        case .initialized(_, let info):
            if !info.sessionID.isEmpty, session.agentSessionID != info.sessionID {
                session = session.with {
                    $0.agentSessionID = info.sessionID
                    $0.updatedAt = Date()
                }
                await save(session)
            }

        case .result(_, let result):
            session = session.with {
                $0.inputTokens += result.usage.inputTokens
                $0.outputTokens += result.usage.outputTokens
                $0.costUSD += result.usage.costUSD
                $0.contextTokens = result.usage.contextTokens
                $0.state = result.isError ? .failed : .idle
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
        try? await store.append(Message(
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
        // Another turn may have initialised the counter while this one was awaiting the store.
        if let seq = nextSeq {
            nextSeq = seq + 1
            return seq
        }
        nextSeq = stored + 1
        return stored
    }

    private func save(_ session: Session) async {
        try? await store.upsert(session)
    }

    // MARK: Finishing

    private func finish(status: Int32, sawResult: Bool) async {
        alive = false
        process = nil
        killTask?.cancel()
        killTask = nil
        stderrTask?.cancel()
        stderrTask = nil
        sink.finish()

        guard !cancelled else { return }

        if status != 0, !sawResult {
            let tail = stderrTail.joined(separator: "\n")
            let payload = (try? JSONEncoder().encode(ProcessFailure(status: Int(status), stderr: tail)))
                ?? Data("{\"type\":\"error\"}".utf8)
            await persist(kind: .error, payload: payload)

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

    /// SIGTERM now, SIGKILL in three seconds if the agent is still around. Claude Code usually
    /// wants a moment to flush, but it does not get to hang the app.
    public func cancel() {
        guard let proc = process, !cancelled else { return }
        cancelled = true

        session = session.with {
            $0.state = .cancelled
            $0.updatedAt = Date()
        }
        let snapshot = session
        Task { [store] in try? await store.upsert(snapshot) }

        proc.closeStdin()
        proc.terminate()

        killTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            if proc.isRunning { proc.kill() }
            await self?.markStopped()
        }
    }

    private func markStopped() {
        alive = false
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

    /// Stored as an `.error` row when the process dies without ever emitting a `result`.
    private struct ProcessFailure: Encodable {
        let type = "error"
        let subtype = "process_exit"
        let status: Int
        let stderr: String
    }
}

// MARK: - Event sink

/// Holds the events continuation outside the actor, so the `events` accessor can be nonisolated.
/// An `AsyncStream.Continuation` is already thread safe, so no lock is needed here.
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

// MARK: - Permission modes

public extension PermissionMode {
    /// What `--permission-mode` expects. Baton's names happen to match the CLI's today, but the
    /// two vocabularies are not the same thing and drift is a matter of time.
    var cliValue: String {
        switch self {
        case .auto: "auto"
        case .acceptEdits: "acceptEdits"
        case .bypassPermissions: "bypassPermissions"
        case .plan: "plan"
        }
    }
}
