import BloomCore

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
    /// Whether any workspace in this project has finished a turn nobody has read yet.
    ///
    /// Computed over every workspace the project has, not over `workspaces`. The rows are what
    /// the filter is letting through, and a filter that hides the unread one would otherwise make
    /// the project claim there is nothing waiting, which is the opposite of what the mark is for.
    var hasUnreadWork: Bool

    var id: String { repo.id }

    /// Pinned first, then the user's own order, matching `AppModel.workspaces(in:)`.
    static func build(
        repos: [Repo],
        workspaces: [Workspace],
        filter: SidebarFilter
    ) -> [SidebarRepoGroup] {
        var byRepo: [String: [Workspace]] = [:]
        for workspace in workspaces {
            byRepo[workspace.repoID, default: []].append(workspace)
        }

        return repos.map { repo in
            let all = byRepo[repo.id] ?? []
            let rows = all.filter(filter.accepts).sorted { lhs, rhs in
                if lhs.pinned != rhs.pinned { return lhs.pinned }
                return lhs.sortOrder < rhs.sortOrder
            }
            return SidebarRepoGroup(
                repo: repo, workspaces: rows, hasUnreadWork: all.contains(where: \.unread)
            )
        }
    }
}
