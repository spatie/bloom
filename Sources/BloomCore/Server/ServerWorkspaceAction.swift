import Foundation

public enum ServerWorkspaceAction: Codable, Sendable, Equatable {
    case rename(String)
    case setPinned(Bool)
    case setUnread(Bool)
    case setColour(String?)
    case runSetup
    /// Protocol 15. See `ServerSetupOutput`.
    case setupOutput
    case archivePreview
    /// `removingDocker` is the owner's answer to the confirmation's Docker choice. Absent means
    /// keep, so a client that never showed the choice cannot remove a database by omission.
    case archive(confirmation: UUID, removingDocker: Bool? = nil)
    case restore
    /// Protocol 16. What deleting this archived workspace permanently would remove, computed on the
    /// server and kept there. See `ServerRemovalPreview`.
    case deletePreview
    /// Protocol 16. Deletes an archived workspace's records, agent transcripts and browser profile.
    case delete(confirmation: UUID)
    case files
    case pullRequest
    case runScripts
    case browserAddress
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
        case .archivePreview, .deletePreview, .files, .download, .pullRequest, .runScripts, .browserAddress, .notes, .setupOutput: false
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
