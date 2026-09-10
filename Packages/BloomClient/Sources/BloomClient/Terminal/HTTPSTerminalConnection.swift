import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Browser cookies never authenticate terminal control. HTTPSConnection supplies the API token.
public actor HTTPSTerminalConnection: RemoteTerminalConnection {
    private let socket: URLSessionWebSocketTask
    private var closed = false
    private var reading = false

    private init(socket: URLSessionWebSocketTask) { self.socket = socket }

    public static func open(connection: HTTPSConnection, workspaceID: String, name: String) async throws -> HTTPSTerminalConnection {
        let socket = try await connection.terminal(workspaceID: workspaceID, name: name)
        return HTTPSTerminalConnection(socket: socket)
    }

    public func read() async throws -> Data? {
        guard !closed else { return nil }
        guard !reading else { throw ConnectionFailure("Only one terminal reader can attach to a connection.") }
        reading = true
        defer { reading = false }
        do {
            let message = try await socket.receive()
            guard !closed else { return nil }
            guard case .data(let data) = message, data.count <= 65_536 else {
                throw ConnectionFailure("The terminal returned an invalid output frame.")
            }
            return data
        } catch {
            if closed || socket.closeCode == .normalClosure { return nil }
            throw error
        }
    }

    public func send(_ data: Data) async throws {
        _ = try RemoteTerminalFrame.input(data)
        guard !closed else { throw ConnectionFailure("Reconnect the terminal before typing.") }
        try await socket.send(.data(data))
    }

    public func resize(columns: Int, rows: Int) async throws {
        let frame = try RemoteTerminalFrame.resize(columns: columns, rows: rows)
        guard !closed else { throw ConnectionFailure("Reconnect the terminal before resizing.") }
        try await socket.send(.string(String(decoding: JSONEncoder().encode(frame), as: UTF8.self)))
    }

    public func close() {
        guard !closed else { return }
        closed = true
        socket.cancel(with: .normalClosure, reason: nil)
    }
}
