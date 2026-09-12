import Foundation

/// Read projections intentionally omit database lifecycle setters and host filesystem behaviour.
/// Contract tests decode the server's real Codable values into these views of the same records.
public struct RemoteCatalogue: Decodable, Sendable {
    public let repositories: [RemoteProject]
    public let workspaces: [RemoteWorkspace]
    public let sessions: [RemoteSession]
    public let archivedWorkspaces: [RemoteWorkspace]

    private enum CodingKeys: CodingKey { case repositories, workspaces, sessions, archivedWorkspaces }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        repositories = try values.decode([RemoteProject].self, forKey: .repositories)
        workspaces = try values.decode([RemoteWorkspace].self, forKey: .workspaces)
        sessions = try values.decode([RemoteSession].self, forKey: .sessions)
        archivedWorkspaces = try values.decodeIfPresent([RemoteWorkspace].self, forKey: .archivedWorkspaces) ?? []
    }

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
    public let defaultBranch: String?
}

public struct RemoteWorkspace: Decodable, Sendable, Identifiable {
    public let path: String?
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
    public let refID: String?
    public let durationMS: Int?

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
    public let queuedPrompts: [RemoteQueuedPrompt]
    public let permissionDecisions: [String: String]

    private enum CodingKeys: CodingKey {
        case session, messages, pendingQuestions, isBusy, streamingText, queueError, queuedPrompts, permissionDecisions
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        session = try values.decode(RemoteSession.self, forKey: .session)
        messages = try values.decode([RemoteMessage].self, forKey: .messages)
        pendingQuestions = try values.decode([Data].self, forKey: .pendingQuestions)
        isBusy = try values.decode(Bool.self, forKey: .isBusy)
        streamingText = try values.decode(String.self, forKey: .streamingText)
        queueError = try values.decodeIfPresent(String.self, forKey: .queueError)
        queuedPrompts = try values.decodeIfPresent([RemoteQueuedPrompt].self, forKey: .queuedPrompts) ?? []
        permissionDecisions = try values.decodeIfPresent([String: String].self, forKey: .permissionDecisions) ?? [:]
    }

    public static func decode(_ result: JSONValue) throws -> Self {
        guard let payload = result["transcript"]?["_0"] else { throw ConnectionFailure("The server did not return this conversation.") }
        return try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(payload))
    }
}

public struct RemoteQueuedPrompt: Codable, Sendable, Identifiable, Equatable {
    public let id: DeliveryID
    public let text: String

    public init(id: DeliveryID, text: String) { self.id = id; self.text = text }
}
