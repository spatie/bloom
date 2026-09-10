import Foundation

/// Bound short refreshes independently of long-running commands. Cancellation must reach the
/// transport, and a timeout never replays the command or manufactures another request identity.
public enum RemoteReadDeadline {
    public static func request(_ command: RemoteCommand, using client: any RemoteRequesting,
                               timeout: Duration = .seconds(20)) async throws -> JSONValue {
        try await run(timeout: timeout) { try await client.request(command) }
    }

    public static func run<Value: Sendable>(timeout: Duration = .seconds(20),
                                            operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { tasks in
            tasks.addTask { try await operation() }
            tasks.addTask {
                try await Task.sleep(for: timeout)
                throw ConnectionFailure("The server is taking too long to reply. Bloom will reconnect.")
            }
            defer { tasks.cancelAll() }
            guard let reply = try await tasks.next() else { throw CancellationError() }
            return reply
        }
    }
}
