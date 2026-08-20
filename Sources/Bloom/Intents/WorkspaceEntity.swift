import AppIntents
import BloomCore

/// One Bloom workspace, as Shortcuts sees it.
///
/// The fields are `@Property` rather than plain values so a Shortcut can branch on them. Status
/// and diff size are the whole reason to ask about a workspace from a script, and a Shortcut can
/// only read what the entity publishes.
struct WorkspaceEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Bloom Workspace",
        numericFormat: "\(placeholder: .int) workspaces"
    )

    static let defaultQuery = WorkspaceEntityQuery()

    var id: String

    @Property(title: "Name") var name: String
    @Property(title: "Project") var project: String
    @Property(title: "Branch") var branch: String
    @Property(title: "Folder") var folder: String
    @Property(title: "Status") var status: WorkspaceStatusAppEnum
    @Property(title: "Agent Running") var isAgentRunning: Bool
    @Property(title: "Lines Added") var additions: Int
    @Property(title: "Lines Removed") var deletions: Int
    @Property(title: "Changed Files") var changedFiles: Int
    /// Empty when there is no pull request, and empty just as much when nobody asked GitHub. The
    /// intents that do not shell out to `gh` say so in their own description rather than dressing
    /// an unasked question up as a "no".
    @Property(title: "Pull Request") var pullRequest: String
    @Property(title: "Pull Request URL") var pullRequestURL: String

    init(
        workspace: Workspace,
        project: String,
        isAgentRunning: Bool,
        isAwaitingPermission: Bool = false,
        pullRequest: PullRequest?
    ) {
        self.id = workspace.id
        self.name = workspace.name
        self.project = project
        self.branch = workspace.branch
        self.folder = workspace.path
        self.status = WorkspaceStatusAppEnum(
            WorkspaceStatus.resolve(
                workspace: workspace,
                isRunning: isAgentRunning,
                pullRequest: pullRequest,
                isAwaitingPermission: isAwaitingPermission
            )
        )
        self.isAgentRunning = isAgentRunning
        self.additions = workspace.additions
        self.deletions = workspace.deletions
        self.changedFiles = workspace.changedFiles
        self.pullRequest = pullRequest.map { "#\($0.number) \($0.title)" } ?? ""
        self.pullRequestURL = pullRequest?.url ?? ""
    }

    /// The project comes first in the subtitle because the same branch name lives in several
    /// repositories at once, and a picker showing six rows called "fix-tests" is no picker at all.
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(project), \(statusLabel)"
        )
    }

    private var statusLabel: String {
        WorkspaceStatusAppEnum.caseDisplayRepresentations[status]
            .map { String(localized: $0.title) } ?? status.rawValue
    }
}
