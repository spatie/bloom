import Foundation

/// Read projections intentionally omit database lifecycle setters and host filesystem behaviour.
/// Contract tests decode the server's real Codable values into these views of the same records.
public struct RemoteCatalogue: Decodable, Sendable {
    public let repositories: [RemoteProject]
    public let workspaces: [RemoteWorkspace]
    public let sessions: [RemoteSession]

    public static func decode(_ result: JSONValue) throws -> Self {
        guard let payload = result["catalogue"]?["_0"] else { throw ConnectionFailure("The server did not return its workspaces.") }
        return try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(payload))
    }
}

public struct RemoteProject: Decodable, Sendable, Identifiable {
    public let id: RepoID
    public let name: String
    public let path: String
    public let hidden: Bool
}

public struct RemoteWorkspace: Decodable, Sendable, Identifiable {
    public let id: WorkspaceID
    public let repoID: RepoID
    public let name: String
    public let branch: String
    public let setupState: String
    public let setupLog: String
    public let port: Int
}

public struct RemoteSession: Decodable, Sendable, Identifiable {
    public let id: SessionID
    public let workspaceID: WorkspaceID?
    public let title: String
    public let model: String
    public let agentKind: String
    public let state: String
}

public struct RemoteMessage: Decodable, Sendable, Identifiable, Equatable {
    public let id: Int64
    public let seq: Int
    public let kind: String
    public let payload: Data

    public var text: String {
        guard let value = JSONValue.parse(payload) else { return String(decoding: payload, as: UTF8.self) }
        if let text = value["text"]?.stringValue { return text }
        if let text = value["message"]?.stringValue { return text }
        let content = value["message"]?["content"] ?? value["content"]
        if let text = content?.stringValue { return text }
        if let blocks = content?.arrayValue {
            let text = blocks.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
            if !text.isEmpty { return text }
        }
        return value.prettyPrinted
    }
}

public struct RemoteTranscript: Decodable, Sendable {
    public let session: RemoteSession
    public let messages: [RemoteMessage]
    public let pendingQuestions: [Data]
    public let isBusy: Bool
    public let streamingText: String
    public let queueError: String?

    public static func decode(_ result: JSONValue) throws -> Self {
        guard let payload = result["transcript"]?["_0"] else { throw ConnectionFailure("The server did not return this conversation.") }
        return try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(payload))
    }
}
