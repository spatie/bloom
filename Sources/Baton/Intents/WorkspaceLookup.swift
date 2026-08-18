import Foundation
import BatonCore

/// Turns stored rows into `WorkspaceEntity` values, in one place, so a picker, a list and a status
/// question cannot disagree about what a workspace is.
enum WorkspaceLookup {
    /// Whether an agent has a turn open is a fact about a live process, and the only trace of it
    /// outside the app is the session row the runner marks `running`. Baton resets those rows on
    /// launch, so a stale one cannot survive a crash and claim an agent that is long gone.
    static func isAgentRunning(workspaceID: String, store: Store) async -> Bool {
        let sessions = (try? await store.sessions(workspaceID: workspaceID)) ?? []
        return sessions.contains { $0.state == .running }
    }

    /// `includePullRequests` costs one `gh` subprocess per workspace, which is why it is off
    /// wherever the caller is a picker or an unbounded list. GitHub's answer is cached for a
    /// minute, so asking about the same workspace twice in one Shortcut only pays once.
    static func entities(
        for workspaces: [Workspace],
        store: Store,
        includePullRequests: Bool
    ) async throws -> [WorkspaceEntity] {
        let repos = try await store.repos()
        let names = Dictionary(uniqueKeysWithValues: repos.map { ($0.id, $0.name) })

        var entities: [WorkspaceEntity] = []
        for workspace in workspaces {
            entities.append(
                WorkspaceEntity(
                    workspace: workspace,
                    project: names[workspace.repoID] ?? "Unknown project",
                    isAgentRunning: await isAgentRunning(workspaceID: workspace.id, store: store),
                    pullRequest: includePullRequests ? await pullRequest(for: workspace) : nil
                )
            )
        }
        return entities
    }

    /// Nil for every reason at once: gh missing, signed out, no pull request, or a worktree that
    /// somebody removed from under Baton. None of those is worth failing an intent over, so the
    /// workspace falls back to what git alone can say about it.
    static func pullRequest(for workspace: Workspace) async -> PullRequest? {
        guard FileManager.default.fileExists(atPath: workspace.path) else { return nil }
        return try? await GitHub.pullRequest(
            forBranch: workspace.branch, worktree: workspace.path, maxAge: .seconds(60)
        )
    }
}
