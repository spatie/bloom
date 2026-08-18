import BatonCore

/// One project and the workspaces the filter is letting through.
///
/// The sidebar used to ask `AppModel.workspaces(in:)` from inside every `RepoSection`'s body,
/// which filtered and sorted the whole workspace list once per project on every redraw. A running
/// agent updates its diff stat every few seconds, so that is a redraw a second across every
/// project the user has open. Grouping is a single pass over the list instead, run when the
/// workspaces, the projects or the filter actually change.
struct SidebarRepoGroup: Identifiable {
    var repo: Repo
    var workspaces: [Workspace]

    var id: String { repo.id }

    /// Pinned first, then the user's own order, matching `AppModel.workspaces(in:)`.
    static func build(
        repos: [Repo],
        workspaces: [Workspace],
        filter: SidebarFilter
    ) -> [SidebarRepoGroup] {
        var byRepo: [String: [Workspace]] = [:]
        for workspace in workspaces where filter.accepts(workspace) {
            byRepo[workspace.repoID, default: []].append(workspace)
        }

        return repos.map { repo in
            let rows = (byRepo[repo.id] ?? []).sorted { lhs, rhs in
                if lhs.pinned != rhs.pinned { return lhs.pinned }
                return lhs.sortOrder < rhs.sortOrder
            }
            return SidebarRepoGroup(repo: repo, workspaces: rows)
        }
    }
}
