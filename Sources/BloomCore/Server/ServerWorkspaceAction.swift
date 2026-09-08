import Foundation

public enum ServerWorkspaceAction: Codable, Sendable, Equatable {
    case files
    case pullRequest
    case runScripts
    case runScript(id: String)
    case download(path: String)
    case writeFile(path: String, text: String, revision: String)
    case uploadFile(name: String, data: Data)
    case commit(message: String)
    case push
    case createPullRequest(title: String, body: String, draft: Bool)
    case terminal(name: String)
    case closeTerminal(name: String)
    case notes
    case saveNotes(String)
    case newSession(agent: AgentKind, model: String, effort: String, permissionMode: PermissionMode)

    var mutates: Bool {
        switch self {
        case .files, .download, .pullRequest, .runScripts, .notes: false
        default: true
        }
    }
}

public struct ServerTerminalPane: Identifiable, Codable, Sendable, Equatable {
    public var id: TerminalTabID
    public var title: String

    public init(id: String, title: String) { self.id = TerminalTabID(id); self.title = title }
}

public struct ServerTerminal: Codable, Sendable {
    public var executable: String
    public var socket: String
    public var session: String
}

public struct ServerDownload: Codable, Sendable {
    public var path: String
    public var data: Data
}
