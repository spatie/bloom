import Foundation

/// Request associations and the generation that prevents late reads restoring cleared numbers.
extension Store {
    private func requestGenerationKey(_ repoID: RepoID) -> String { "repo.\(repoID).requestGeneration" }

    public func observePullRequest(workspaceID: WorkspaceID) throws -> PullRequestObservation? {
        guard let workspace = try workspace(id: workspaceID) else { return nil }
        return PullRequestObservation(workspace: workspace, generation: try setting(requestGenerationKey(workspace.repoID)) ?? "")
    }

    /// Returns false when the lookup has been superseded, even if there is no number to write.
    public func acceptPullRequestRead(_ found: PullRequest?, observed: PullRequestObservation) throws -> Bool {
        guard let current = try workspace(id: observed.workspace.id),
              current.path == observed.workspace.path, current.branch == observed.workspace.branch,
              (try setting(requestGenerationKey(current.repoID)) ?? "") == observed.generation else { return false }
        if let found, found.number > 0 { try recordPullRequestNumber(found.number, workspaceID: current.id) }
        return true
    }

    public func clearPullRequestNumbers(repoID: RepoID) throws {
        try db.transaction {
            try setSetting(requestGenerationKey(repoID), UUID().uuidString)
            try db.run(
                "UPDATE workspaces SET pull_request_number = NULL WHERE repo_id = ? AND pull_request_number IS NOT NULL",
                [.text(repoID)]
            )
        }
    }
}
