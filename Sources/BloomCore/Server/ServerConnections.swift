import Foundation
import Synchronization

/// RPC sockets belong to the daemon, including idle clients and reads waiting on Git. Closing
/// the listener alone leaves these tasks alive beyond the data-directory ownership lock.
final class ServerConnections: Sendable {
    typealias Handler = @Sendable (ServerRequest) async -> ServerReply
    private struct State {
        var closed = false
        var sockets: [ObjectIdentifier: UnixSocketConnection] = [:]
        var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    }
    private let state = Mutex(State())
    private let handler: Handler
    private let connectionLimit: Int
    private let requestLimit: Int

    init(connectionLimit: Int = 64, requestLimit: Int = 32, handler: @escaping Handler) {
        self.connectionLimit = max(1, connectionLimit)
        self.requestLimit = max(1, requestLimit)
        self.handler = handler
    }

    func accept(_ connection: UnixSocketConnection) {
        state.withLock { state in
            guard !state.closed, state.sockets.count < connectionLimit else { connection.close(); return }
            let id = ObjectIdentifier(connection)
            state.sockets[id] = connection
            state.tasks[id] = Task {
                let requests = ServerConnectionRequests(connection: connection, limit: requestLimit, handler: handler)
                await requests.run()
                self.state.withLock { state in
                    state.sockets[id] = nil
                    state.tasks[id] = nil
                }
            }
        }
    }

    func stop() {
        let active = state.withLock { state in
            state.closed = true
            return (Array(state.sockets.values), Array(state.tasks.values))
        }
        for socket in active.0 { socket.close() }
        for task in active.1 { task.cancel() }
    }

    func drain() async {
        let tasks = state.withLock { Array($0.tasks.values) }
        for task in tasks { await task.value }
    }
}

private actor ServerConnectionRequests {
    private let connection: UnixSocketConnection
    private let limit: Int
    private let handler: ServerConnections.Handler
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(connection: UnixSocketConnection, limit: Int, handler: @escaping ServerConnections.Handler) {
        self.connection = connection
        self.limit = limit
        self.handler = handler
    }

    func run() async {
        for await line in connection.lines {
            guard !Task.isCancelled, tasks.count < limit, line.utf8.count <= 16_777_216,
                  let request = try? JSONDecoder().decode(ServerRequest.self, from: Data(line.utf8)) else { break }
            // Use a connection-local identity: duplicate durable command IDs must still reach
            // ServerRuntime's idempotency check, without overwriting the first task's lifetime.
            let id = UUID()
            tasks[id] = Task {
                let reply = await handler(request)
                if !Task.isCancelled, let data = try? JSONEncoder().encode(reply) {
                    await connection.writeLineAsync(String(decoding: data, as: UTF8.self))
                }
                tasks[id] = nil
            }
        }
        connection.close()
        let pending = Array(tasks.values)
        for task in pending { task.cancel() }
        // Mutations accepted by ServerRuntime have their own durable task. Cancelling this
        // response waiter cannot undo them; shutdown still waits until their outcome is known.
        for task in pending { await task.value }
    }
}
