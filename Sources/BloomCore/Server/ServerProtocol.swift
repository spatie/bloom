import Foundation

/// Versioned values cross the connection; database handles and local file URLs never do.
public struct ServerRequest: Codable, Sendable, Equatable {
    public static let protocolVersion = 2
    public var version: Int
    public var id: UUID
    public var operation: ServerOperation

    public init(_ operation: ServerOperation, id: UUID = UUID(), version: Int = protocolVersion) {
        self.version = version
        self.id = id
        self.operation = operation
    }
}

public enum ServerOperation: Codable, Sendable, Equatable {
    case hello
    case catalogue
    case create(ServerWorkspaceRequest)
    case transcript(sessionID: SessionID, afterSeq: Int)
    case changes(workspaceID: WorkspaceID, scope: ServerDiffScope)
    case patch(workspaceID: WorkspaceID, path: String, scope: ServerDiffScope)
    case file(workspaceID: WorkspaceID, path: String)
    case send(sessionID: SessionID, text: String)
    case stop(sessionID: SessionID)
    case answer(sessionID: SessionID, requestID: String, answer: ServerAnswer)

    var mutates: Bool {
        switch self {
        case .hello, .catalogue, .transcript, .changes, .patch, .file: false
        case .create, .send, .stop, .answer: true
        }
    }
}

public struct ServerWorkspaceRequest: Codable, Sendable, Equatable {
    public var repositoryPath: String
    public var name: String
    public var agent: AgentKind
    public var model: String
    public var effort: String
    public var permissionMode: PermissionMode

    public init(
        repositoryPath: String, name: String, agent: AgentKind = .claudeCode,
        model: String = AppDefaults.fallbackModel, effort: String = AppDefaults.fallbackEffort,
        permissionMode: PermissionMode = .plan
    ) {
        self.repositoryPath = repositoryPath
        self.name = name
        self.agent = agent
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
    }
}

public enum ServerAnswer: Codable, Sendable, Equatable {
    case allowOnce
    case deny
    case question(input: JSONValue)

    var decision: PermissionDecision {
        switch self {
        case .allowOnce: .allow(scope: .once)
        case .deny: .deny(message: PermissionDecision.defaultDenyMessage, endsTurn: false)
        case .question(let input): .answer(input: input)
        }
    }
}

public struct ServerReply: Codable, Sendable {
    public var version = ServerRequest.protocolVersion
    public var id: UUID
    public var result: ServerResult

    public init(id: UUID, result: ServerResult) {
        self.id = id
        self.result = result
    }
}

public enum ServerResult: Codable, Sendable {
    case hello(name: String)
    case catalogue(ServerCatalogue)
    case created(session: Session, workspace: Workspace, setupSucceeded: Bool?)
    case transcript(ServerTranscript)
    case changes([ChangedFile])
    case patch(String)
    case file(ServerTextFile)
    case accepted
    case failure(String)
}

public enum ServerDiffScope: String, Codable, Sendable, CaseIterable {
    case branch
    case uncommitted

    var gitScope: DiffScope { self == .branch ? .all : .uncommitted }
}

public struct ServerTextFile: Codable, Sendable {
    public var path: String
    public var text: String
}

public struct ServerCatalogue: Codable, Sendable {
    public var repositories: [Repo]
    public var workspaces: [Workspace]
    public var sessions: [Session]
}

public struct ServerTranscript: Codable, Sendable {
    public var session: Session
    public var messages: [Message]
    public var pendingQuestions: [Data]
    public var isBusy: Bool
    public var streamingText: String
}

struct ServerCommandRecord: Codable {
    var request: ServerRequest
    var reply: ServerReply?
}

public struct ServerFailure: Error, LocalizedError, Sendable {
    public var message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

/// A received refusal has a known outcome. Transport failures do not, so clients retain the
/// command ID only for the latter when offering a retry after reconnecting.
public struct ServerRefusal: Error, LocalizedError, Sendable {
    public var message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}
