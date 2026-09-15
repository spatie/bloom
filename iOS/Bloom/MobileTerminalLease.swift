import Foundation
import BloomClient

/// Window disconnection revokes terminal transports while tmux remains owned by the server.
actor MobileTerminalLease: RemoteTerminalConnection {
    private let id: UUID
    private let connection: any RemoteTerminalConnection
    private let didClose: @MainActor @Sendable (UUID) -> Void
    private var closed = false

    init(id: UUID, connection: any RemoteTerminalConnection, didClose: @escaping @MainActor @Sendable (UUID) -> Void) {
        self.id = id; self.connection = connection; self.didClose = didClose
    }
    func read() async throws -> Data? {
        guard !closed else { return nil }
        do {
            let data = try await connection.read()
            guard !closed else { return nil }
            if data == nil { await close() }
            return data
        } catch {
            await close()
            throw error
        }
    }
    func send(_ data: Data) async throws {
        guard !closed else { throw ConnectionFailure("Reconnect the terminal before typing.") }
        try await connection.send(data)
    }
    func resize(columns: Int, rows: Int) async throws {
        guard !closed else { return }
        try await connection.resize(columns: columns, rows: rows)
    }
    func close() async {
        guard !closed else { return }
        closed = true
        await connection.close()
        await didClose(id)
    }
}
