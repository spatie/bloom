import Foundation

public enum BloomWire {
    public static let version = 13
}

/// The command ID survives a transport failure. Retrying this value cannot create another turn.
public struct RemoteCommand: Codable, Sendable, Equatable {
    public let version: Int
    public let id: UUID
    public let operation: JSONValue

    public init(_ operation: JSONValue, id: UUID = UUID()) {
        version = BloomWire.version
        self.id = id
        self.operation = operation
    }

    public static func call(_ name: String, _ arguments: [String: JSONValue] = [:]) -> Self {
        Self(.object([name: .object(arguments)]))
    }

    public static func send(sessionID: SessionID, text: String) -> Self {
        call("send", ["sessionID": .string(sessionID.rawValue), "text": .string(text)])
    }

    public static func stop(sessionID: SessionID) -> Self {
        call("stop", ["sessionID": .string(sessionID.rawValue)])
    }
}

public protocol RemoteRequesting: Sendable {
    func request(_ command: RemoteCommand) async throws -> JSONValue
}

public final class RemoteClient: RemoteRequesting, Sendable {
    private let connection: HTTPSConnection

    public init(connection: HTTPSConnection) { self.connection = connection }

    public func request(_ command: RemoteCommand) async throws -> JSONValue {
        let data = try await connection.exchange(JSONEncoder().encode(command))
        return try Self.decode(data, commandID: command.id)
    }

    public static func decode(_ data: Data, commandID: UUID) throws -> JSONValue {
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.version == BloomWire.version, reply.id == commandID else {
            throw ConnectionFailure("The server returned an incompatible Bloom reply.")
        }
        if let failure = reply.result["failure"]?["_0"]?.stringValue { throw ConnectionRefusal(failure) }
        return reply.result
    }

    private struct Reply: Decodable {
        let version: Int
        let id: UUID
        let result: JSONValue
    }
}
