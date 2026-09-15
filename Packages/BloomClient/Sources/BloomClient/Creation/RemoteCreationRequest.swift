import Foundation

public struct RemoteCreationRequest: Codable, Sendable, Equatable {
    public var repositoryPath: String
    public var name: String
    public var agent: AgentKind
    public var model: String
    public var effort: String
    public var permissionMode: PermissionMode

    public var prompt: String?
    public var baseBranch: String?
    public var checkout: WorkspaceCheckout?
    public var controls: ComposerControls?
    public var mode: WorkspaceStartMode?
    public var runSetupScript: Bool?
    public var attachments: [ServerInitialAttachment]?

    public init(
        repositoryPath: String, name: String, agent: AgentKind = .claudeCode,
        model: String = ComposerFallbacks.model, effort: String = ComposerFallbacks.effort,
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
