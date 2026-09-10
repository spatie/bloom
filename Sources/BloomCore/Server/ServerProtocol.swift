import Foundation
import BloomClient

/// Versioned values cross the connection; database handles and local file URLs never do.
public struct ServerRequest: Codable, Sendable, Equatable {
    public static let protocolVersion = BloomWire.version
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
    case uiBridge(RemoteUIBridgeOperation)
    case hello
    case diagnostics
    case reviewSnapshot(workspaceID: WorkspaceID, scope: ServerDiffScope, knownRevision: String?, wait: Bool)
    case reviewPatch(workspaceID: WorkspaceID, path: String, scope: ServerDiffScope, knownRevision: String?)
    case creation(ServerCreationOperation)
    case catalogue
    case previewAddress(String)
    case terminalStream(workspaceID: WorkspaceID, name: String)
    case project(repoID: RepoID, action: ServerProjectAction)
    case composer(sessionID: SessionID)
    case setComposer(sessionID: SessionID, controls: ComposerControls)
    case markRead(sessionID: SessionID, seq: Int)
    case renameSession(sessionID: SessionID, title: String)
    case closeSession(sessionID: SessionID)
    case create(ServerWorkspaceRequest)
    case transcript(sessionID: SessionID, afterSeq: Int)
    case changes(workspaceID: WorkspaceID, scope: ServerDiffScope)
    case patch(workspaceID: WorkspaceID, path: String, scope: ServerDiffScope)
    case file(workspaceID: WorkspaceID, path: String)
    case workspace(workspaceID: WorkspaceID, action: ServerWorkspaceAction)
    case configure(sessionID: SessionID, model: String, effort: String, permissionMode: PermissionMode)
    case send(sessionID: SessionID, text: String)
    case cancelQueued(sessionID: SessionID, deliveryID: DeliveryID)
    case stop(sessionID: SessionID)
    case answer(sessionID: SessionID, requestID: String, answer: ServerAnswer)

    var mutates: Bool {
        switch self {
        case .uiBridge, .reviewSnapshot, .reviewPatch, .hello, .diagnostics, .catalogue, .previewAddress, .transcript, .changes, .patch, .file, .composer: false
        case .creation(let action): action.mutates
        case .project(_, let action): action.mutates
        case .create, .send, .stop, .answer, .configure, .cancelQueued, .setComposer, .markRead, .renameSession, .closeSession, .terminalStream: true
        case .workspace(_, let action): action.mutates
        }
    }
}

public typealias ServerWorkspaceRequest = BloomClient.RemoteCreationRequest

public enum ServerAnswer: Codable, Sendable, Equatable {
    case allowOnce
    case allowSession
    case allowProject
    case deny
    case denyWithReason(message: String, endsTurn: Bool)
    case approvePlan(mode: PermissionMode)
    case question(input: JSONValue)

    public init(_ decision: PermissionDecision) {
        switch decision {
        case .allow(.once): self = .allowOnce
        case .allow(.session): self = .allowSession
        case .allow(.project): self = .allowProject
        case .deny(let message, let endsTurn): self = .denyWithReason(message: message, endsTurn: endsTurn)
        case .approvePlan(let mode): self = .approvePlan(mode: mode)
        case .answer(let input): self = .question(input: input)
        }
    }

    var decision: PermissionDecision {
        switch self {
        case .allowOnce: .allow(scope: .once)
        case .allowSession: .allow(scope: .session)
        case .allowProject: .allow(scope: .project)
        case .deny: .deny(message: PermissionDecision.defaultDenyMessage, endsTurn: false)
        case .denyWithReason(let message, let endsTurn): .deny(message: message, endsTurn: endsTurn)
        case .approvePlan(let mode): .approvePlan(mode: mode)
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
    case uiBridge(RemoteUIBridgeResult)
    case reviewSnapshot(ServerReviewSnapshot)
    case reviewPatch(ServerPatchSnapshot)
    case hello(name: String)
    case diagnostics(ServerDiagnostics)
    case creation(ServerCreationResult)
    case catalogue(ServerCatalogue)
    case composer(ServerComposerState)
    case created(session: Session, workspace: Workspace, setupSucceeded: Bool?)
    case transcript(ServerTranscript)
    case changes([ChangedFile])
    case patch(String)
    case file(ServerTextFile)
    case files([String])
    case text(String)
    case download(ServerDownload)
    case terminal(ServerTerminal)
    case runScripts([RunScript])
    case terminalPane(ServerTerminalPane)
    case archivePreview(ServerArchivePreview)
    case projectSettings(ServerProjectSettings)
    case filesToCopy(FilesToCopyPlan)
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
    public var revision: String

    public init(path: String, text: String) {
        self.path = path
        self.text = text
        revision = ServerFileOperations.revision(Data(text.utf8))
    }
}

public struct ServerCatalogue: Codable, Sendable {
    public var repositories: [Repo]
    public var workspaces: [Workspace]
    public var sessions: [Session]
    public var archivedWorkspaces: [Workspace] = []
}

public struct ServerTranscript: Codable, Sendable {
    public var session: Session
    public var messages: [Message]
    public var pendingQuestions: [Data]
    public var isBusy: Bool
    public var streamingText: String
    public var permissionDecisions: [String: String]
    public var queuedPrompts: [ServerQueuedPrompt]
    public var queueError: String?
}

struct ServerCommandRecord: Codable {
    var request: ServerRequest
    var reply: ServerReply?
}

public typealias ServerFailure = BloomClient.ConnectionFailure
public typealias ServerRefusal = BloomClient.ConnectionRefusal
