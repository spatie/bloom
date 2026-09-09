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
    private let wire: RemoteWireSession

    public init(connection: HTTPSConnection) {
        wire = RemoteWireSession { try await connection.exchange($0) }
    }

    public func request(_ command: RemoteCommand) async throws -> JSONValue {
        try await wire.request(command)
    }

    public static func decode(_ data: Data, commandID: UUID, expectedVersion: Int = BloomWire.version) throws -> JSONValue {
        let reply = try RemoteWireReply.decode(data, commandID: commandID)
        guard [12, BloomWire.version].contains(expectedVersion), reply.version == expectedVersion else {
            throw ConnectionRefusal("This server uses Bloom protocol \(reply.version), but this app needs \(expectedVersion). Update Bloom Server and the app to matching versions, then reconnect.")
        }
        if let failure = reply.result["failure"]?["_0"]?.stringValue { throw ConnectionRefusal(failure) }
        return reply.result
    }
}
