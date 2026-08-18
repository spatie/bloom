import AppIntents
import BatonCore

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

    /// Branch as well as name, because half the time the thing the user remembers about a
    /// workspace is what it is called on GitHub.
    func entities(matching string: String) async throws -> [WorkspaceEntity] {
        let needle = string.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return try await suggestedEntities() }

        let store = try await IntentDatabase.store()
        let workspaces = try await store.workspaces().filter {
            $0.name.lowercased().contains(needle) || $0.branch.lowercased().contains(needle)
        }
        return try await WorkspaceLookup.entities(
            for: workspaces, store: store, includePullRequests: false
        )
    }
}
