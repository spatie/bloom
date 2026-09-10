import Foundation
import BloomClient

/// A client owns a connection, never an agent. Explicit disconnect and transport failure finish
/// waiting requests; neither sends Stop or asks the standalone server to exit.
public actor ServerClient: RemoteRequesting {
    private let socket: UnixSocketConnection?
    private let process: StreamingProcess?
    private let http: ServerHTTPTransport?
    private var pump: Task<Void, Never>?
    private var errorPump: Task<Void, Never>?
    private struct PendingReply {
        let attempt: UUID
        let continuation: CheckedContinuation<Data, Error>
    }
    private var pending: [UUID: PendingReply] = [:]
    private var wire: RemoteWireSession?
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
        let operation = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(request.operation))
        let value: JSONValue
        do {
            value = try await ServerWireTimeout.$duration.withValue(timeout) {
                try await self.request(RemoteCommand(operation, id: request.id))
            }
        } catch let error as ConnectionRefusal { throw ServerRefusal(error.localizedDescription) }
        var reply = ServerReply(id: request.id, result: try JSONDecoder().decode(ServerResult.self, from: JSONEncoder().encode(value)))
        reply.version = await wire?.negotiatedVersion ?? ServerRequest.protocolVersion
        return reply
    }

    public func request(_ command: RemoteCommand) async throws -> JSONValue {
        guard !isClosed else { throw ServerFailure("The server connection is closed. Reconnect to continue.") }
        if wire == nil {
            wire = RemoteWireSession { [weak self] body in
                guard let self else { throw ServerFailure("The server connection closed.") }
                return try await self.exchange(body, timeout: ServerWireTimeout.duration)
            }
        }
        return try await wire!.request(command)
    }

    private func exchange(_ body: Data, timeout: Duration) async throws -> Data {
        guard !isClosed else { throw ServerFailure("The server connection is closed. Reconnect to continue.") }
        if let http { return try await http.exchange(body, timeout: timeout) }
        let id = try JSONDecoder().decode(ServerWireIdentity.self, from: body).id
        guard pending[id] == nil else { throw ServerFailure("This command is already awaiting a reply.") }
        let line = String(decoding: body, as: UTF8.self)
        let attempt = UUID()
        let deadline = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            await self?.fail(id, attempt: attempt, message: "The server did not reply. Reconnect and refresh before retrying.")
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = PendingReply(attempt: attempt, continuation: continuation)
                if let socket {
                    Task { [weak self] in
                        guard await self?.maySend(id, attempt: attempt) == true else { return }
                        await socket.writeLineAsync(line)
                    }
                } else { process?.writeLine(line) }
            }
        } onCancel: {
            Task { await self.fail(id, attempt: attempt, message: "The request was cancelled. It may still be running on the server.") }
        }
    }

    private func receive(_ line: String) {
        let data = Data(line.utf8)
        guard data.count <= 16_777_216, let reply = try? JSONDecoder().decode(ServerWireIdentity.self, from: data) else {
            disconnect(message: "The server sent an invalid reply.")
            return
        }
        pending.removeValue(forKey: reply.id)?.continuation.resume(returning: data)
    }

    private func maySend(_ id: UUID, attempt: UUID) -> Bool {
        !isClosed && pending[id]?.attempt == attempt
    }

    private func fail(_ id: UUID, attempt: UUID, message: String) {
        guard pending[id]?.attempt == attempt else { return }
        pending.removeValue(forKey: id)?.continuation.resume(throwing: ServerFailure(message))
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
        for reply in waiting { reply.continuation.resume(throwing: ServerFailure(message)) }
    }

    deinit {
        socket?.close()
        process?.terminate()
        pump?.cancel()
        errorPump?.cancel()
    }
}

private struct ServerWireIdentity: Decodable { let id: UUID }
private enum ServerWireTimeout { @TaskLocal static var duration: Duration = .seconds(660) }
