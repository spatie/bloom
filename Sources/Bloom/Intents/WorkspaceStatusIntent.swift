import AppIntents
import BloomCore

/// One workspace, answered fully: what state it is in, whether an agent has a turn open, how big
/// the diff is and what GitHub thinks of the branch.
struct WorkspaceStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Workspace Status"

    static let description = IntentDescription(
        """
        Returns one Bloom workspace with its status, whether an agent is running, its diff stat \
        and its pull request.
        """,
        categoryName: "Workspaces",
        resultValueName: "Workspace"
    )

    @Parameter(title: "Workspace")
    var workspace: WorkspaceEntity

    @Parameter(
        title: "Ask GitHub",
        description: "Looks the pull request up with gh. Turn it off to answer from Bloom's database alone.",
        default: true
    )
    var includePullRequest: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Get the status of \(\.$workspace)") {
            \.$includePullRequest
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<WorkspaceEntity> {
        let store = try await IntentDatabase.store()
        // Re-read rather than trusting the entity handed in: it may have been sitting in a
        // Shortcut's variable since before the turn that changed everything about it.
        guard let row = try await store.workspace(id: workspace.id) else {
            throw IntentFailure.unknownWorkspace
        }
        guard let repo = try await store.repo(id: row.repoID) else {
            throw IntentFailure.unknownProject
        }

        let entity = WorkspaceEntity(
            workspace: row,
            project: repo.name,
            isAgentRunning: await WorkspaceLookup.isAgentRunning(workspaceID: row.id, store: store),
            isAwaitingPermission: await WorkspaceLookup.isAwaitingPermission(workspaceID: row.id, store: store),
            pullRequest: includePullRequest ? await WorkspaceLookup.pullRequest(for: row) : nil
        )
        return .result(value: entity, dialog: "\(entity.name): \(summary(for: entity, row: row))")
    }

    private func summary(for entity: WorkspaceEntity, row: Workspace) -> String {
        var text = WorkspaceStatusAppEnum.caseDisplayRepresentations[entity.status]
            .map { String(localized: $0.title) } ?? entity.status.rawValue
        if row.hasDiff {
            text += ", \(row.changedFiles) files, plus \(row.additions) minus \(row.deletions)"
        }
        return text
    }
}
