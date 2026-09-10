import Foundation

/// Pulling output lets a native terminal apply backpressure instead of dropping ANSI bytes.
public protocol RemoteTerminalConnection: Sendable {
    func read() async throws -> Data?
    func send(_ data: Data) async throws
    func resize(columns: Int, rows: Int) async throws
    /// Detach the transport. The server-owned shell remains available for another attachment.
    func close() async
}

public struct TerminalRelayHandshake: Codable, Sendable {
    public let terminalProtocol: Int
    public let terminalSocket: String

    public init(socketPath: String) throws {
        guard Self.isAllowedPath(socketPath) else { throw ConnectionFailure("The server returned an invalid terminal stream address.") }
        terminalProtocol = 1
        terminalSocket = socketPath
    }

    public static func isAllowedPath(_ path: String) -> Bool {
        let prefix = "/tmp/bloom-terminal-"
        guard path.hasPrefix(prefix), path.hasSuffix(".sock") else { return false }
        let identifier = String(path.dropFirst(prefix.count).dropLast(5))
        return UUID(uuidString: identifier) != nil && identifier.count == 36
    }
}

public struct RemoteTerminalFrame: Codable, Sendable {
    public var kind: String
    public var data: Data?
    public var columns: Int?
    public var rows: Int?

    public init(kind: String, data: Data? = nil, columns: Int? = nil, rows: Int? = nil) {
        self.kind = kind; self.data = data; self.columns = columns; self.rows = rows
    }

    public static func input(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 16_384 else { throw ConnectionFailure("Send terminal input in chunks up to 16 KB.") }
        return Self(kind: "input", data: data)
    }

    public static func resize(columns: Int, rows: Int) throws -> Self {
        guard (2...500).contains(columns), (2...300).contains(rows) else { throw ConnectionFailure("The terminal size is outside the supported range.") }
        return Self(kind: "resize", columns: columns, rows: rows)
    }
}
