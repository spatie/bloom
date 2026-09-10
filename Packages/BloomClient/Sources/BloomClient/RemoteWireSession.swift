import Foundation

/// Negotiates the explicitly supported wire formats before any user command is sent.
/// Only a hello may be retried. A mutation always leaves with its original durable command ID.
public actor RemoteWireSession: RemoteRequesting {
    public typealias Exchange = @Sendable (Data) async throws -> Data
    private let exchange: Exchange
    private var established: Handshake?
    private var pending: Task<Void, Never>?
    private var pendingID: UUID?
    private var waiters: [UUID: CheckedContinuation<Handshake, Error>] = [:]
    var handshakeWaiterCount: Int { waiters.count }
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
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                waiters[waiterID] = continuation
                guard pending == nil else { return }
                let id = UUID()
                pendingID = id
                let exchange = exchange
                pending = Task { [weak self] in
                    let result: Result<Handshake, Error>
                    do { result = .success(try await Self.handshake(id: helloID, exchange: exchange)) } catch { result = .failure(error) }
                    await self?.finishHandshake(result, id: id)
                }
            }
        } onCancel: {
            Task { await self.cancelHandshake(waiterID: waiterID) }
        }
    }

    private func finishHandshake(_ result: Result<Handshake, Error>, id: UUID) {
        guard pendingID == id else { return }
        let waiting = waiters.values
        waiters = [:]; pending = nil; pendingID = nil
        if case .success(let connection) = result { established = connection }
        for continuation in waiting { continuation.resume(with: result) }
    }

    private func cancelHandshake(waiterID: UUID) {
        waiters.removeValue(forKey: waiterID)?.resume(throwing: CancellationError())
        guard waiters.isEmpty else { return }
        pendingID = nil
        pending?.cancel()
        pending = nil
    }

    deinit { pending?.cancel() }

    private struct Handshake: Sendable {
        let version: Int
        let result: JSONValue
    }

    private static func handshake(id: UUID, exchange: Exchange) async throws -> Handshake {
        let hello = RemoteCommand(.object(["hello": .object([:])]), id: id)
        let initial = try await exchange(encode(hello, version: BloomWire.version))
        try Task.checkCancellation()
        let reply = try RemoteWireReply.decode(initial, commandID: id)
        if reply.version != BloomWire.version, BloomWire.supportedVersions.contains(reply.version),
           reply.result == .object(["failure": .object(["_0": .string("Incompatible Bloom server protocol. Update the client and server.")])]) {
            let data = try await exchange(encode(hello, version: reply.version))
            try Task.checkCancellation()
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
