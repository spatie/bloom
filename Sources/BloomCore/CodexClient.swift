import Foundation

/// One `codex app-server` process, spoken to in JSON-RPC.
///
/// The process is long lived exactly as the Claude Code one is: stdin stays open, a follow-up turn
/// is one more line, and the thread id survives so a restarted app can resume. `StreamingProcess`
/// already does line-delimited JSON over a held-open stdin, so nothing about it had to change.
///
/// Three things separate this from `AgentRunner`'s reader, and all three come from JSON-RPC rather
/// than from Codex:
///
///   1. **Requests have replies.** Every call gets an id and waits for the frame carrying it back,
///      so `thread/start` can return a thread id instead of a notification arriving later that
///      somebody has to correlate by hand.
///   2. **The server asks too.** Approvals are server-to-client requests, and a client that cannot
///      answer would leave every one of them hanging until the turn timed out. `answer(_:with:)`
///      is that half.
///   3. **stderr is not part of the protocol.** The server writes tracing there (`ERROR
///      codex_core::tools::router` was observed during a refused patch), so `mergeStderr` is off.
///      Merging it would put non-JSON lines into the frame stream.
///
/// One connection can carry several threads, so nothing here is bound to a session. A Bloom
/// session picks its thread id out of the events it cares about.
public actor CodexClient {
    // MARK: Configuration

    public struct Configuration: Sendable {
        public var executable: String
        /// The directory the agent works in. Passed per thread as well, because `turn/start` can
        /// override it, but the process is launched here so relative paths in tracing make sense.
        public var cwd: String
        /// `CODEX_HOME`, when it must not be the user's. Absent means the real one, which is what
        /// the app wants and what a test must never touch.
        public var codexHome: String?
        public var clientName: String
        public var clientVersion: String
        public var environment: [String: String]

        public init(
            executable: String = CodexClient.executable,
            cwd: String,
            codexHome: String? = nil,
            clientName: String = "Bloom",
            clientVersion: String = "0.0.0",
            environment: [String: String] = Shell.environment()
        ) {
            self.executable = executable
            self.cwd = cwd
            self.codexHome = codexHome
            self.clientName = clientName
            self.clientVersion = clientVersion
            self.environment = environment
        }
    }

    public static let executable = "codex"

    /// `--listen stdio://` is the default, and it is written out anyway: the flag is what says this
    /// is the stdio transport rather than the unix socket or websocket ones the same binary
    /// serves, and a default that changes underneath us would be silent.
    public static let arguments = ["app-server", "--listen", "stdio://"]

    public static func launch(_ configuration: Configuration) -> AgentLaunch {
        var environment = configuration.environment
        if let home = configuration.codexHome, !home.isEmpty {
            environment["CODEX_HOME"] = home
        }
        return AgentLaunch(
            executable: configuration.executable,
            arguments: arguments,
            cwd: configuration.cwd,
            environment: environment
        )
    }

    // MARK: State

    private let configuration: Configuration
    private let makeProcess: @Sendable (AgentLaunch) -> any AgentProcessing
    private var process: (any AgentProcessing)?
    private var readTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?

    private var nextRequestID = 1
    private var pending: [CodexRequestID: CheckedContinuation<JSONValue, Error>] = [:]
    private var handshakeCompleted = false
    private var closedReason: String?

    /// stderr, kept short. It only ever surfaces when the process dies without answering, which is
    /// the one moment a tracing line is worth reading.
    private var stderrTail: [String] = []
    private static let stderrTailLimit = 40

    private let sink = EventSink()

    public init(
        configuration: Configuration,
        makeProcess: @escaping @Sendable (AgentLaunch) -> any AgentProcessing = CodexClient.spawn
    ) {
        self.configuration = configuration
        self.makeProcess = makeProcess
    }

    public static let spawn: @Sendable (AgentLaunch) -> any AgentProcessing = { launch in
        StreamingProcess(
            executable: launch.executable,
            arguments: launch.arguments,
            cwd: launch.cwd,
            environment: launch.environment,
            mergeStderr: false
        )
    }

    /// Decoded events, as a fresh stream per caller.
    ///
    /// Nonisolated so a view can start consuming before the handshake has finished, which means it
    /// reads no actor state: the sink is a reference box built at init. The same shape as
    /// `AgentRunner.events`, and for the same reason: one shared stream would let the first
    /// consumer to walk away finish it for everybody.
    public nonisolated var events: AsyncStream<CodexEvent> { sink.stream() }

    public var isRunning: Bool { process?.isRunning ?? false }

    public var isReady: Bool { handshakeCompleted }

    /// The tail of the server's own tracing, for an error message that would otherwise say only
    /// that the process is gone.
    public var diagnostics: [String] { stderrTail }

    // MARK: Lifecycle

    /// Launches the server and completes the handshake.
    ///
    /// `initialize` is a request and `initialized` is a notification, in that order. Nothing else
    /// may be sent in between: the server rejects work before the handshake, and sending
    /// `initialized` without waiting for the reply races the connection's own setup.
    public func start() async throws {
        guard process == nil else { return }

        let process = makeProcess(Self.launch(configuration))
        self.process = process
        readTask = Task { [weak self] in await self?.readLines(from: process) }
        stderrTask = Task { [weak self] in await self?.readErrors(from: process) }

        _ = try await send(
            "initialize",
            params: .object(omittingNil: [
                "clientInfo": .object([
                    "name": .string(configuration.clientName),
                    "version": .string(configuration.clientVersion),
                ]),
                // Experimental methods are not opted into: everything Bloom needs is in the stable
                // surface, and opting in would mean fields that can change without notice.
                "capabilities": .object(["experimentalApi": .bool(false)]),
            ])
        )
        notify("initialized", params: nil)
        handshakeCompleted = true
    }

    /// Ends the connection. Closing stdin is the polite version and the server exits on it, which
    /// was verified: every recorded run ends with the process exiting 0 after the pipe closed.
    public func stop() {
        process?.closeStdin()
        process?.terminate()
        finish(reason: "The Codex connection was closed")
    }

    // MARK: Sending

    /// One request, awaited until its reply comes back.
    ///
    /// The continuation is filed before the line is written, because a reply can arrive on the
    /// reader task the instant the write lands and a continuation registered afterwards would miss
    /// it. Both halves run on the actor, so the ordering holds.
    @discardableResult
    public func send(_ method: String, params: JSONValue?) async throws -> JSONValue {
        if let closedReason { throw CodexClientError.connectionClosed(closedReason) }
        guard process != nil else { throw CodexClientError.notInitialized }

        let id = CodexRequestID.number(nextRequestID)
        nextRequestID += 1

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            write(CodexOutgoing.request(id: id, method: method, params: params))
        }
    }

    public func notify(_ method: String, params: JSONValue?) {
        write(CodexOutgoing.notification(method: method, params: params))
    }

    /// Answers one of the server's own requests. Without this an approval hangs.
    public func answer(_ id: CodexRequestID, with result: JSONValue) {
        write(CodexOutgoing.response(id: id, result: result))
    }

    public func answer(_ request: CodexApprovalRequest, decision: CodexApprovalDecision) {
        answer(request.id, with: decision.result(for: request.kind))
    }

    private func write(_ line: String) {
        process?.writeLine(line)
    }

    // MARK: Typed calls

    /// Starts a thread and returns its id.
    ///
    /// `sandbox` is the kebab-case `SandboxMode` (`read-only`, `workspace-write`,
    /// `danger-full-access`), which is **not** the camelCase `SandboxPolicy` that `turn/start`
    /// takes. Sending `readOnly` here is rejected outright with "unknown variant `readOnly`", which
    /// is how the difference was found.
    public func startThread(
        cwd: String? = nil,
        model: String? = nil,
        approvalPolicy: CodexApprovalPolicy? = nil,
        sandbox: CodexSandboxMode? = nil
    ) async throws -> CodexThreadHandle {
        let result = try await send("thread/start", params: .object(omittingNil: [
            "cwd": .string(cwd ?? configuration.cwd),
            "model": model.map(JSONValue.string),
            "approvalPolicy": approvalPolicy.map { .string($0.rawValue) },
            "sandbox": sandbox.map { .string($0.rawValue) },
        ]))
        guard let id = result["thread"]?["id"]?.stringValue else {
            throw CodexClientError.unexpectedResult(method: "thread/start")
        }
        return CodexThreadHandle(
            id: id,
            model: result["model"]?.stringValue ?? "",
            effort: result["reasoningEffort"]?.stringValue
        )
    }

    /// Reopens a thread by its id. Verified against the real server: the id that comes back is the
    /// one that went in, so a resumed Bloom session keeps the same `agentSessionID` forever.
    @discardableResult
    public func resumeThread(
        _ threadID: String,
        cwd: String? = nil,
        model: String? = nil,
        sandbox: CodexSandboxMode? = nil
    ) async throws -> CodexThreadHandle {
        let result = try await send("thread/resume", params: .object(omittingNil: [
            "threadId": .string(threadID),
            "cwd": .string(cwd ?? configuration.cwd),
            "model": model.map(JSONValue.string),
            "sandbox": sandbox.map { .string($0.rawValue) },
        ]))
        return CodexThreadHandle(
            id: result["thread"]?["id"]?.stringValue ?? threadID,
            model: result["model"]?.stringValue ?? "",
            effort: result["reasoningEffort"]?.stringValue
        )
    }

    /// Sends one turn and returns as soon as the server has accepted it.
    ///
    /// The reply is the turn in `inProgress`, not the finished one: waiting for the answer means
    /// waiting for the `turn/completed` notification. That is the shape a live transcript wants
    /// anyway, and getting it wrong is how a first attempt at this closed the connection while the
    /// model was still typing.
    ///
    /// Model, effort, approval policy and sandbox are all per turn on this protocol, which fits
    /// Bloom's composer chips better than Claude Code does: changing the model chip mid chat takes
    /// effect on the next turn without restarting anything.
    @discardableResult
    public func startTurn(
        threadID: String,
        input: [CodexUserInput],
        model: String? = nil,
        effort: String? = nil,
        approvalPolicy: CodexApprovalPolicy? = nil,
        sandboxPolicy: JSONValue? = nil
    ) async throws -> CodexTurn {
        let result = try await send("turn/start", params: .object(omittingNil: [
            "threadId": .string(threadID),
            "input": .array(input.map(\.json)),
            "model": model.map(JSONValue.string),
            "effort": effort.flatMap { $0.isEmpty ? nil : .string($0) },
            "approvalPolicy": approvalPolicy.map { .string($0.rawValue) },
            "sandboxPolicy": sandboxPolicy,
        ]))
        return CodexTurn.decode(result["turn"] ?? .null, threadID: threadID, raw: Data())
    }

    /// Stops a running turn. Both ids are required: `turn/interrupt` with only a thread id is
    /// refused with "missing field `turnId`".
    public func interruptTurn(threadID: String, turnID: String) async throws {
        _ = try await send("turn/interrupt", params: .object([
            "threadId": .string(threadID),
            "turnId": .string(turnID),
        ]))
    }

    /// The models this account may use, with each one's own reasoning efforts.
    public func listModels(includeHidden: Bool = false) async throws -> [CodexModel] {
        let result = try await send("model/list", params: .object([
            "includeHidden": .bool(includeHidden),
        ]))
        return CodexModel.decodeList(result)
    }

    // MARK: Reading

    private func readLines(from process: any AgentProcessing) async {
        do {
            for try await line in process.lines {
                guard let frame = CodexFrame.decode(line: line) else { continue }
                handle(frame)
            }
            finish(reason: "The Codex process ended")
        } catch {
            finish(reason: error.readableMessage)
        }
    }

    private func readErrors(from process: any AgentProcessing) async {
        for await line in process.errorLines {
            stderrTail.append(line)
            if stderrTail.count > Self.stderrTailLimit { stderrTail.removeFirst() }
        }
    }

    private func handle(_ frame: CodexFrame) {
        switch frame {
        case .response(let id, let result, _):
            pending.removeValue(forKey: id)?.resume(returning: result)

        case .failure(let id, let error, _):
            pending.removeValue(forKey: id)?.resume(throwing: error)

        case .request(let request):
            // Only the five approval shapes are answered by a person. The other five
            // server-to-client requests are the server asking the client for machinery
            // (`attestation/generate`, a token refresh) and are refused rather than half
            // understood, so the turn fails visibly instead of hanging.
            if let approval = CodexApprovalRequest.decode(request) {
                sink.yield(.approval(approval))
            } else {
                write(CodexOutgoing.failure(
                    id: request.id,
                    code: -32601,
                    message: "Bloom does not implement \(request.method)"
                ))
            }

        case .notification(let notification):
            sink.yield(CodexEvent.decode(notification))

        case .malformed(let raw):
            sink.yield(.unknown(method: "", raw: raw))
        }
    }

    /// Fails everything still waiting and closes the event stream. Called once.
    private func finish(reason: String) {
        guard closedReason == nil else { return }
        closedReason = reason

        let waiters = pending
        pending.removeAll()
        for (_, continuation) in waiters {
            continuation.resume(throwing: CodexClientError.connectionClosed(reason))
        }

        sink.yield(.closed(reason: reason))
        sink.finish()
        readTask = nil
        stderrTask = nil
    }

    // MARK: Event sink

    /// Fans one stream of events out to however many consumers there are, and hands each of them
    /// its own stream so one going away does not end the session for the rest.
    private final class EventSink: @unchecked Sendable {
        private let lock = NSLock()
        private var continuations: [UUID: AsyncStream<CodexEvent>.Continuation] = [:]
        private var finished = false

        func stream() -> AsyncStream<CodexEvent> {
            let id = UUID()
            return AsyncStream(bufferingPolicy: .unbounded) { continuation in
                lock.lock()
                let alreadyFinished = finished
                if !alreadyFinished { continuations[id] = continuation }
                lock.unlock()

                if alreadyFinished {
                    continuation.finish()
                    return
                }
                continuation.onTermination = { [weak self] _ in
                    guard let self else { return }
                    lock.lock(); continuations[id] = nil; lock.unlock()
                }
            }
        }

        func yield(_ event: CodexEvent) {
            lock.lock()
            let targets = Array(continuations.values)
            lock.unlock()
            for target in targets { target.yield(event) }
        }

        func finish() {
            lock.lock()
            finished = true
            let targets = Array(continuations.values)
            continuations.removeAll()
            lock.unlock()
            for target in targets { target.finish() }
        }
    }
}

// MARK: - Supporting values

public struct CodexThreadHandle: Sendable, Hashable {
    public let id: String
    public let model: String
    /// Nil until a turn sets one. `thread/start` answers with null, which is not the same as the
    /// model having no default: `model/list` is where a default effort actually lives.
    public let effort: String?

    public init(id: String, model: String = "", effort: String? = nil) {
        self.id = id
        self.model = model
        self.effort = effort
    }
}

/// What a turn is allowed to do without asking.
///
/// Crossed with `CodexSandboxMode`, this is Codex's whole permission story, and it does not map
/// onto Claude Code's four modes: there is no `plan` here, and `acceptEdits` is a point in a grid
/// rather than a mode. `granular` takes an object rather than a word and is left to the permission
/// work.
public enum CodexApprovalPolicy: String, Sendable, Hashable, CaseIterable {
    case untrusted
    case onRequest = "on-request"
    case never
}

/// The kebab-case spelling `thread/start` and `thread/resume` take. `turn/start` takes a different
/// type with the same meanings spelled `readOnly`, `workspaceWrite` and `dangerFullAccess`.
public enum CodexSandboxMode: String, Sendable, Hashable, CaseIterable {
    case readOnly = "read-only"
    case workspaceWrite = "workspace-write"
    case dangerFullAccess = "danger-full-access"
}

/// One piece of what the user sent.
///
/// `localImage` takes a path, so Bloom's existing attachment handling reaches Codex unchanged: the
/// composer already writes a pasted image to disk and carries its path.
public enum CodexUserInput: Sendable, Hashable {
    case text(String)
    case localImage(path: String)

    var json: JSONValue {
        switch self {
        case .text(let text):
            .object(["type": .string("text"), "text": .string(text)])
        case .localImage(let path):
            .object(["type": .string("localImage"), "path": .string(path)])
        }
    }
}
