import Foundation

/// Negotiates the explicitly supported wire formats before any user command is sent.
/// Only a hello may be retried. A mutation always leaves with its original durable command ID.
public actor RemoteWireSession: RemoteRequesting {
    public typealias Exchange = @Sendable (Data) async throws -> Data
    private let exchange: Exchange
    private var established: Handshake?
    private var pending: Task<Handshake, Error>?
    public var negotiatedVersion: Int? { established?.version }

    public init(exchange: @escaping Exchange) { self.exchange = exchange }

    public func request(_ command: RemoteCommand) async throws -> JSONValue {
        try Task.checkCancellation()
        let alreadyEstablished = established != nil
        let isHello = command.operation == .object(["hello": .object([:])])
        let connection = try await negotiate(helloID: isHello ? command.id : UUID())
        try Task.checkCancellation()
        if isHello, !alreadyEstablished { return connection.result }
        if connection.version == 12, command.operation["diagnostics"] != nil {
            throw ConnectionRefusal("Server diagnostics require Bloom Server protocol 13. Other workspace features remain available on this server.")
        }
        if connection.version < 14, command.operation["uiBridge"] != nil {
            throw ConnectionRefusal("Agent UI tools require Bloom Server protocol 14. Update the server to use panes, tabs and browser tools remotely.")
        }
        let data = try await exchange(Self.encode(command, version: connection.version))
        return try RemoteClient.decode(data, commandID: command.id, expectedVersion: connection.version)
    }

    private func negotiate(helloID: UUID) async throws -> Handshake {
        if let established { return established }
        if let pending { return try await pending.value }
        let exchange = exchange
        let task = Task { try await Self.handshake(id: helloID, exchange: exchange) }
        pending = task
        do {
            let result = try await task.value
            established = result
            pending = nil
            return result
        } catch {
            pending = nil
            throw error
        }
    }

    private struct Handshake: Sendable {
        let version: Int
        let result: JSONValue
    }

    private static func handshake(id: UUID, exchange: Exchange) async throws -> Handshake {
        let hello = RemoteCommand(.object(["hello": .object([:])]), id: id)
        let initial = try await exchange(encode(hello, version: BloomWire.version))
        let reply = try RemoteWireReply.decode(initial, commandID: id)
        if reply.version != BloomWire.version, BloomWire.supportedVersions.contains(reply.version),
           reply.result == .object(["failure": .object(["_0": .string("Incompatible Bloom server protocol. Update the client and server.")])]) {
            let data = try await exchange(encode(hello, version: reply.version))
            let result = try RemoteClient.decode(data, commandID: id, expectedVersion: reply.version)
            return try validatedHello(result, version: reply.version)
        }
        let result = try RemoteClient.decode(initial, commandID: id)
        return try validatedHello(result, version: BloomWire.version)
    }

    private static func validatedHello(_ result: JSONValue, version: Int) throws -> Handshake {
        guard result["hello"]?["name"]?.stringValue != nil else {
            throw ConnectionRefusal("This endpoint did not identify itself as a Bloom Server.")
        }
        return Handshake(version: version, result: result)
    }

    private static func encode(_ command: RemoteCommand, version: Int) throws -> Data {
        struct Envelope: Encodable {
            let version: Int
            let id: UUID
            let operation: JSONValue
        }
        return try JSONEncoder().encode(Envelope(version: version, id: command.id, operation: command.operation))
    }
}

/// ID validation precedes negotiation, so an unrelated reply can never choose a protocol.
struct RemoteWireReply: Decodable {
    let version: Int
    let id: UUID
    let result: JSONValue

    static func decode(_ data: Data, commandID: UUID) throws -> Self {
        let reply = try JSONDecoder().decode(Self.self, from: data)
        guard reply.id == commandID else {
            throw ConnectionFailure("The server replied to a different request. Reconnect before retrying.")
        }
        return reply
    }
}
