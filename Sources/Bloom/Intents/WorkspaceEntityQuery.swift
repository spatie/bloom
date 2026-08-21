import AppIntents
import BloomCore

/// Lets Shortcuts offer the real workspaces in a picker instead of asking somebody to type a UUID.
struct WorkspaceEntityQuery: EntityStringQuery {
    func entities(for identifiers: [WorkspaceEntity.ID]) async throws -> [WorkspaceEntity] {
        let store = try await IntentDatabase.store()
        let wanted = Set(identifiers)
        let workspaces = try await store.workspaces(includeArchived: true)
            .filter { wanted.contains($0.id) }
        return try await WorkspaceLookup.entities(
            for: workspaces, store: store, includePullRequests: false
        )
    }

    /// Archived workspaces are left out of everything a picker offers. Their worktree is gone from
    /// disk, so every question a Shortcut could ask about one has already been answered by
    /// deleting it.
    func suggestedEntities() async throws -> [WorkspaceEntity] {
        let store = try await IntentDatabase.store()
        return try await WorkspaceLookup.entities(
            for: try await store.workspaces(), store: store, includePullRequests: false
        )
    }

    /// Branch and project as well as name, because half the time the thing the user remembers
    /// about a workspace is what it is called on GitHub or which project it is in. The rule is
    /// `WorkspaceSearch`, the same one the search field and Home's filter use: this used to match
    /// two of the three fields, so a workspace findable by typing was not findable by asking.
    func entities(matching string: String) async throws -> [WorkspaceEntity] {
        let needle = WorkspaceSearch.needle(string)
        guard !needle.isEmpty else { return try await suggestedEntities() }

        let store = try await IntentDatabase.store()
        var reposByID: [RepoID: Repo] = [:]
        for repo in try await store.repos() { reposByID[repo.id] = repo }
        let workspaces = try await store.workspaces().filter {
            WorkspaceSearch.match(
                workspace: $0, repo: reposByID[$0.repoID], needle: needle
            ) != nil
        }
        return try await WorkspaceLookup.entities(
            for: workspaces, store: store, includePullRequests: false
        )
    }
}
