import Foundation
import BloomClient
import Synchronization

/// One `grok agent stdio` process, spoken to in ACP JSON-RPC.
///
/// The process is long lived: stdin stays open, a follow-up turn is another `session/prompt`,
/// and the session id survives so a restarted app can `session/resume`. `StreamingProcess`
/// already does line-delimited JSON over a held-open stdin.
///
/// Three things separate this from `AgentRunner`'s reader, and all three come from JSON-RPC:
///
///   1. **Requests have replies.** `session/new` returns a session id instead of a notification
///      arriving later that somebody has to correlate by hand.
///   2. **The server asks too.** `session/request_permission` is a server-to-client request, and
///      a client that cannot answer would leave every one hanging until the turn timed out.
///   3. **`session/prompt` is the turn.** Unlike Codex's `turn/start`, which returns immediately,
///      ACP holds the prompt request open until the turn ends. Bloom therefore must not wait on
///      it inside `send`: the reply is an event, and a 120 second timeout would kill a real turn.
public actor GrokClient {
    public struct Configuration: Sendable {
        public var executable: String
        public var cwd: String
        public var grokHome: String?
        public var clientName: String
        public var clientVersion: String
        public var environment: [String: String]
        public var model: String
        public var effort: String
        public var alwaysApprove: Bool

        public init(
            executable: String = GrokClient.executable,
            cwd: String,
            grokHome: String? = nil,
            clientName: String = "Bloom",
            clientVersion: String = "0.0.0",
            environment: [String: String] = Shell.environment(),
            model: String = "",
            effort: String = "",
            alwaysApprove: Bool = false
        ) {
            self.executable = executable
            self.cwd = cwd
            self.grokHome = grokHome
            self.clientName = clientName
            self.clientVersion = clientVersion
            self.environment = environment
            self.model = model
            self.effort = effort
            self.alwaysApprove = alwaysApprove
        }
    }

    public static let executable = "grok"
    public static let arguments = ["agent", "--no-leader", "stdio"]

    public static func launch(_ configuration: Configuration) -> AgentLaunch {
        var environment = configuration.environment
        environment["GROK_DISABLE_AUTOUPDATER"] = "1"
        if let home = configuration.grokHome, !home.isEmpty {
            environment["GROK_HOME"] = home
        }
        var arguments: [String] = ["agent"]
        if configuration.alwaysApprove { arguments.append("--always-approve") }
        if !configuration.model.isEmpty {
            arguments += ["--model", configuration.model]
        }
        if !configuration.effort.isEmpty {
            arguments += ["--reasoning-effort", configuration.effort]
        }
        arguments += ["--no-leader", "stdio"]
        return AgentLaunch(
            executable: configuration.executable,
            arguments: arguments,
            cwd: configuration.cwd,
            environment: environment
        )
    }

    private let configuration: Configuration
    private let makeProcess: @Sendable (AgentLaunch) -> any AgentProcessing
    private var process: (any AgentProcessing)?
    private let live = LiveProcess()
    private var readTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?

    private var nextRequestID = 1
    private var pending: [GrokRequestID: CheckedContinuation<JSONValue, Error>] = [:]
    /// Prompt requests are not waited on. Their ids live here so the reply becomes an event
    /// rather than resuming a continuation that would pin `send` to the whole turn.
    private var promptIDs: Set<GrokRequestID> = []
    private var handshakeCompleted = false
    private var closedReason: String?
    private var advertised: [GrokModel] = []
    private var currentModelID = ""

    private var stderrTail: [String] = []
    private static let stderrTailLimit = 40

    private let sink = EventFanout<GrokEvent>()

    public init(
        configuration: Configuration,
        makeProcess: @escaping @Sendable (AgentLaunch) -> any AgentProcessing = GrokClient.spawn
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

    public nonisolated var events: AsyncStream<GrokEvent> { sink.stream() }

    public var isRunning: Bool { process?.isRunning ?? false }

    public nonisolated var isProcessAlive: Bool { live.current?.isRunning ?? false }

    public var isClosed: Bool { closedReason != nil }

    public var isReady: Bool { handshakeCompleted }

    public var diagnostics: [String] { stderrTail }

    public func advertisedModels() -> [GrokModel] { advertised }

    public static let requestTimeout = Duration.seconds(120)

    // MARK: Lifecycle

    public func start() async throws {
        guard process == nil else { return }

        let process = makeProcess(Self.launch(configuration))
        self.process = process
        live.attach(process)

        let errors = process.errorLines
        let lines = process.lines
        readTask = Task { [weak self] in await self?.readLines(from: lines) }
        stderrTask = Task { [weak self] in await self?.readErrors(from: errors) }

        let result = try await send(
            "initialize",
            params: .object([
                "protocolVersion": .integer(1),
                "clientInfo": .object([
                    "name": .string(configuration.clientName),
                    "version": .string(configuration.clientVersion),
                ]),
                // Empty on purpose. Advertising `fs` or `terminal` makes the agent ask Bloom to
                // read files and run commands; Bloom is not that client. Grok has its own tools.
                "clientCapabilities": .object([:]),
            ])
        )
        let modelState = result["_meta"]?["modelState"] ?? .null
        advertised = GrokModel.decodeList(modelState)
        currentModelID = modelState["currentModelId"]?.stringValue ?? ""
        notify("initialized", params: .object([:]))
        handshakeCompleted = true
    }

    public func stop() {
        terminateNow()
        finish(reason: "The Grok connection was closed")
    }

    public nonisolated func terminateNow() {
        guard let process = live.claimForSignal() else { return }
        process.closeStdin()
        process.terminate()
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, process.isRunning else { return }
            process.kill()
        }
    }

    // MARK: Sending

    @discardableResult
    public func send(
        _ method: String, params: JSONValue?, timeout: Duration = GrokClient.requestTimeout
    ) async throws -> JSONValue {
        if let closedReason { throw GrokClientError.connectionClosed(closedReason) }
        guard process != nil else { throw GrokClientError.notInitialized }

        let id = GrokRequestID.number(nextRequestID)
        nextRequestID += 1

        let watchdog = Task { [weak self] in
            try await Task.sleep(for: timeout)
            await self?.abandon(id, method: method, after: timeout)
        }
        defer { watchdog.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            write(GrokOutgoing.request(id: id, method: method, params: params))
        }
    }

    private func abandon(_ id: GrokRequestID, method: String, after timeout: Duration) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(
            throwing: GrokClientError.timedOut(
                method: method, seconds: Int(timeout.components.seconds)
            )
        )
    }

    public func notify(_ method: String, params: JSONValue?) {
        write(GrokOutgoing.notification(method: method, params: params))
    }

    public func answer(_ id: GrokRequestID, with result: JSONValue) {
        write(GrokOutgoing.response(id: id, result: result))
    }

    private func write(_ line: String) {
        process?.writeLine(line)
    }

    // MARK: Typed calls

    public func newSession(
        cwd: String? = nil,
        mcpServers: [JSONValue] = [],
        permissionMode: PermissionMode = .auto
    ) async throws -> GrokSession {
        let result = try await send("session/new", params: sessionParams(
            sessionID: nil,
            cwd: cwd,
            mcpServers: mcpServers,
            permissionMode: permissionMode
        ))
        guard let session = GrokSession.decode(result) else {
            throw GrokClientError.unexpectedResult(method: "session/new")
        }
        if !session.models.isEmpty { advertised = session.models }
        return session
    }

    public func resumeSession(
        _ sessionID: String,
        cwd: String? = nil,
        mcpServers: [JSONValue] = [],
        permissionMode: PermissionMode = .auto
    ) async throws -> GrokSession {
        let result = try await send("session/resume", params: sessionParams(
            sessionID: sessionID,
            cwd: cwd,
            mcpServers: mcpServers,
            permissionMode: permissionMode
        ))
        if let session = GrokSession.decode(result) {
            if !session.models.isEmpty { advertised = session.models }
            return session
        }
        return GrokSession(id: sessionID, models: advertised, currentModelID: currentModelID)
    }

    public func setConfigOption(sessionID: String, configID: String, value: String) async throws {
        _ = try await send("session/set_config_option", params: .object([
            "sessionId": .string(sessionID),
            "configId": .string(configID),
            "value": .object(["value": .string(value)]),
        ]))
    }

    /// Starts a turn without waiting for it. The `session/prompt` reply arrives later as
    /// `.promptCompleted`. Waiting here is how a two minute timeout would kill a real turn.
    ///
    /// The returned id is the turn id. The ACP session id is stable across turns, so it cannot
    /// be used to tell a cancelled prompt's reply from the next send's.
    @discardableResult
    public func beginPrompt(sessionID: String, text: String) throws -> GrokRequestID {
        if let closedReason { throw GrokClientError.connectionClosed(closedReason) }
        guard process != nil else { throw GrokClientError.notInitialized }
        let id = GrokRequestID.number(nextRequestID)
        nextRequestID += 1
        promptIDs.insert(id)
        write(GrokOutgoing.request(
            id: id,
            method: "session/prompt",
            params: .object([
                "sessionId": .string(sessionID),
                "prompt": .array([.object([
                    "type": .string("text"),
                    "text": .string(text),
                ])]),
            ])
        ))
        return id
    }

    public func cancel(sessionID: String) {
        notify("session/cancel", params: .object(["sessionId": .string(sessionID)]))
    }

    public func closeSession(_ sessionID: String) async {
        _ = try? await send("session/close", params: .object(["sessionId": .string(sessionID)]))
    }

    private func sessionParams(
        sessionID: String?,
        cwd: String?,
        mcpServers: [JSONValue],
        permissionMode: PermissionMode
    ) -> JSONValue {
        var members: [String: JSONValue?] = [
            "cwd": .string(cwd ?? configuration.cwd),
            "mcpServers": .array(mcpServers),
            "_meta": .object([
                "yoloMode": .bool(permissionMode == .bypassPermissions),
                "autoMode": .bool(permissionMode == .auto || permissionMode == .autoReview),
                "permissionMode": .string(permissionMode.cliValue),
            ]),
        ]
        if let sessionID { members["sessionId"] = .string(sessionID) }
        return .object(omittingNil: members)
    }

    // MARK: Reading

    private func readLines(from lines: AsyncThrowingStream<String, Error>) async {
        do {
            for try await line in lines {
                guard let frame = GrokFrame.decode(line: line) else { continue }
                handle(frame)
            }
            finish(reason: "The Grok process ended")
        } catch {
            finish(reason: error.readableMessage)
        }
    }

    private func readErrors(from errors: AsyncStream<String>) async {
        for await line in errors {
            stderrTail.append(line)
            if stderrTail.count > Self.stderrTailLimit { stderrTail.removeFirst() }
        }
    }

    private func handle(_ frame: GrokFrame) {
        switch frame {
        case .response(let id, let result, _):
            if promptIDs.remove(id) != nil {
                sink.yield(.promptCompleted(GrokPromptResult(
                    requestID: id,
                    sessionID: result["sessionId"]?.stringValue ?? "",
                    stopReason: result["stopReason"]?.stringValue ?? "end_turn",
                    raw: result
                )))
                return
            }
            pending.removeValue(forKey: id)?.resume(returning: result)

        case .failure(let id, let error, _):
            if promptIDs.remove(id) != nil {
                sink.yield(.promptCompleted(GrokPromptResult(
                    requestID: id,
                    sessionID: "",
                    stopReason: "refusal",
                    raw: .object(["message": .string(error.message)])
                )))
                return
            }
            pending.removeValue(forKey: id)?.resume(throwing: error)

        case .request(let request):
            if let permission = GrokPermissionRequest.decode(request) {
                sink.yield(.permission(permission))
            } else {
                write(GrokOutgoing.failure(
                    id: request.id,
                    code: -32601,
                    message: "Bloom does not implement \(request.method)"
                ))
            }

        case .notification(let notification):
            if notification.method == "session/update",
               let update = GrokSessionUpdate.decode(params: notification.params) {
                sink.yield(.update(update))
            } else {
                sink.yield(.unknown(method: notification.method, raw: notification.raw))
            }

        case .malformed(let raw):
            sink.yield(.unknown(method: "", raw: raw))
        }
    }

    private func finish(reason: String) {
        guard closedReason == nil else { return }
        closedReason = reason

        let waiters = pending
        pending.removeAll()
        for (_, continuation) in waiters {
            continuation.resume(throwing: GrokClientError.connectionClosed(reason))
        }
        promptIDs.removeAll()

        sink.yield(.closed(reason: reason))
        sink.finish()
        process = nil
        readTask = nil
        stderrTask = nil
    }
}

private final class LiveProcess: Sendable {
    private struct State {
        var process: (any AgentProcessing)?
        var signalled = false
    }

    private let state = Mutex(State())

    var current: (any AgentProcessing)? { state.withLock(\.process) }

    func attach(_ process: any AgentProcessing) {
        state.withLock { state in
            state.process = process
            state.signalled = false
        }
    }

    func claimForSignal() -> (any AgentProcessing)? {
        state.withLock { state -> (any AgentProcessing)? in
            guard !state.signalled, let process = state.process else { return nil }
            state.signalled = true
            return process
        }
    }
}
