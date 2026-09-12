import Foundation

/// A client owns a connection, never an agent. Explicit disconnect and transport failure finish
/// waiting requests; neither sends Stop or asks the standalone server to exit.
public actor ServerClient {
    private let socket: UnixSocketConnection?
    private let process: StreamingProcess?
    private let http: ServerHTTPTransport?
    private var pump: Task<Void, Never>?
    private var errorPump: Task<Void, Never>?
    private var pending: [UUID: CheckedContinuation<ServerReply, Error>] = [:]
    private var isClosed = false
    private var stderr = ""

    private init(socket: UnixSocketConnection?, process: StreamingProcess?, http: ServerHTTPTransport? = nil) {
        self.socket = socket
        self.process = process
        self.http = http
    }

    public static func connect(to endpoint: ServerEndpoint, timeout: Duration = .seconds(15), accessToken: ServerHTTPTransport.AccessToken? = nil) async throws -> ServerClient {
        let client: ServerClient
        switch endpoint {
        case .https(let address):
            guard let accessToken else { throw ServerFailure("Sign in to the HTTPS server first.") }
            let http = try ServerHTTPTransport(baseURL: ServerHTTPTransport.origin(address), accessToken: accessToken)
            client = ServerClient(socket: nil, process: nil, http: http)
        case .local(let directory):
            let socket = try UnixSocketConnection.connect(to: ServerDaemon.socketPath(directory: directory))
            client = ServerClient(socket: socket, process: nil)
        case .ssh:
            guard let launch = try endpoint.launch else { throw ServerFailure("Missing SSH configuration.") }
            client = ServerClient(socket: nil, process: StreamingProcess(
                executable: launch.executable, arguments: launch.arguments, cwd: launch.cwd,
                environment: launch.environment, mergeStderr: false
            ))
        }
        await client.start()
        do {
            let reply = try await client.request(ServerRequest(.hello), timeout: timeout)
            guard case .hello = reply.result else { throw ServerFailure("This endpoint is not a Bloom server.") }
            return client
        } catch {
            await client.disconnect()
            throw error
        }
    }

    private func start() {
        if let socket {
            pump = Task { [weak self] in
                for await line in socket.lines { await self?.receive(line) }
                await self?.connectionEnded()
            }
        } else if let process {
            // Accessing lines starts SSH. Do that before returning to the handshake: launching
            // inside the pump task let request() write first, and StreamingProcess correctly
            // drops writes made before launch. Reconnect then waited forever for a lost hello.
            let errors = process.errorLines
            let lines = process.lines
            pump = Task { [weak self] in
                do {
                    for try await line in lines { await self?.receive(line) }
                } catch { /* The transport's stderr supplies the actionable SSH error. */ }
                await self?.connectionEnded()
            }
            errorPump = Task { [weak self] in
                for await line in errors { await self?.recordError(line) }
            }
        }
    }

    public func request(_ request: ServerRequest, timeout: Duration = .seconds(660)) async throws -> ServerReply {
        guard !isClosed else { throw ServerFailure("The server connection is closed. Reconnect to continue.") }
        if let http { return try await http.request(request, timeout: timeout) }
        guard pending[request.id] == nil else { throw ServerFailure("This command is already awaiting a reply.") }
        let line = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        let deadline = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            await self?.fail(request.id, message: "The server did not reply. Reconnect and refresh before retrying.")
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending[request.id] = continuation
                if let socket { socket.writeLine(line) } else { process?.writeLine(line) }
            }
        } onCancel: {
            Task { await self.fail(request.id, message: "The request was cancelled. It may still be running on the server.") }
        }
    }

    private func receive(_ line: String) {
        guard let reply = try? JSONDecoder().decode(ServerReply.self, from: Data(line.utf8)),
              reply.version == ServerRequest.protocolVersion else {
            disconnect(message: "The server sent an incompatible reply.")
            return
        }
        guard let continuation = pending.removeValue(forKey: reply.id) else { return }
        if case .failure(let message) = reply.result { continuation.resume(throwing: ServerRefusal(message)) } else { continuation.resume(returning: reply) }
    }

    private func fail(_ id: UUID, message: String) {
        pending.removeValue(forKey: id)?.resume(throwing: ServerFailure(message))
    }

    private func recordError(_ line: String) { stderr = String((stderr + line + "\n").suffix(4_096)) }

    private func connectionEnded() {
        disconnect(message: stderr.isEmpty ? "The server disconnected. Reconnect to see current progress." : stderr)
    }

    public func disconnect() { disconnect(message: "Disconnected from the server.") }

    private func disconnect(message: String) {
        guard !isClosed else { return }
        isClosed = true
        http?.close()
        socket?.close()
        process?.terminate()
        pump?.cancel()
        errorPump?.cancel()
        pump = nil
        errorPump = nil
        let waiting = pending.values
        pending.removeAll()
        for continuation in waiting { continuation.resume(throwing: ServerFailure(message)) }
    }

    deinit {
        socket?.close()
        process?.terminate()
        pump?.cancel()
        errorPump?.cancel()
    }
}
