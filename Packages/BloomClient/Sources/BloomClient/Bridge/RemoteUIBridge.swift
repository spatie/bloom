import Foundation

/// UI actions retain their existing MCP tool names and named arguments. The server validates
/// them through the normal tool handler before they reach an explicitly attached workspace UI.
public struct RemoteUIAction: Codable, Sendable, Equatable {
    public let name: String
    public let arguments: JSONValue
    public init(name: String, arguments: JSONValue = .object([:])) { self.name = name; self.arguments = arguments }
}

public struct RemoteUIResult: Codable, Sendable, Equatable {
    public let text: String
    public let isError: Bool
    public let value: JSONValue?
    public let png: Data?
    public init(text: String = "", isError: Bool = false, value: JSONValue? = nil, png: Data? = nil) {
        self.text = text; self.isError = isError; self.value = value; self.png = png
    }
    public static func refusal(_ message: String) -> Self { .init(text: message, isError: true) }
}

public struct RemoteUILease: Codable, Sendable, Equatable {
    public let id: UUID
    public let token: String
    public let workspaceID: WorkspaceID
    public let expiresAtMilliseconds: Int64
    public init(id: UUID, token: String, workspaceID: WorkspaceID, expiresAtMilliseconds: Int64) {
        self.id = id; self.token = token; self.workspaceID = workspaceID; self.expiresAtMilliseconds = expiresAtMilliseconds
    }
}

public struct RemoteUIRequest: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let workspaceID: WorkspaceID
    public let action: RemoteUIAction
    public let expiresAtMilliseconds: Int64
    public init(id: UUID, workspaceID: WorkspaceID, action: RemoteUIAction, expiresAtMilliseconds: Int64) {
        self.id = id; self.workspaceID = workspaceID; self.action = action; self.expiresAtMilliseconds = expiresAtMilliseconds
    }
}

public struct RemoteUIBatch: Codable, Sendable, Equatable {
    public let lease: RemoteUILease
    public let requests: [RemoteUIRequest]
    public init(lease: RemoteUILease, requests: [RemoteUIRequest]) { self.lease = lease; self.requests = requests }
}

public enum RemoteUIBridgeOperation: Codable, Sendable, Equatable {
    case attach(workspaceID: WorkspaceID, clientID: UUID, actions: [String])
    case poll(leaseID: UUID, token: String, wait: Bool)
    case claim(leaseID: UUID, token: String, requestID: UUID)
    case respond(leaseID: UUID, token: String, requestID: UUID, result: RemoteUIResult)
    case detach(leaseID: UUID, token: String)
}

public enum RemoteUIBridgeResult: Codable, Sendable, Equatable {
    case attached(RemoteUILease)
    case requests(RemoteUIBatch)
    case claimed(Bool)
    case accepted
}

public extension RemoteWorkspaceService {
    func uiBridge(_ operation: RemoteUIBridgeOperation, commandID: UUID = UUID()) async throws -> RemoteUIBridgeResult {
        let argument = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(operation))
        let response = try await client.request(RemoteCommand(.object(["uiBridge": .object(["_0": argument])]), id: commandID))
        guard let payload = response["uiBridge"]?["_0"] else {
            throw ConnectionFailure("This server does not support workspace UI tools. Update Bloom Server and reconnect.")
        }
        return try JSONDecoder().decode(RemoteUIBridgeResult.self, from: JSONEncoder().encode(payload))
    }
}
