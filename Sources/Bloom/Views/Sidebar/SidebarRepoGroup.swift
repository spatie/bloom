import BloomCore

/// One project and the workspaces the filter is letting through.
///
/// The sidebar used to ask `AppModel.workspaces(in:)` from inside every project section's body,
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

    var id: RepoID { repo.id }

    /// Pinned first, then the user's own order, matching `AppModel.workspaces(in:)`.
    static func build(
        repos: [Repo],
        workspaces: [Workspace],
        filter: SidebarFilter
    ) -> [SidebarRepoGroup] {
        var byRepo: [RepoID: [Workspace]] = [:]
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

/// One row of the pane, in the order the pane draws them.
///
/// The sidebar is a single `ForEach` over this rather than a `Section` per project, because a
/// section header is not a row the list will drag and the projects have to be reorderable. See
/// `SidebarReorder.Row`, which is this list with the drawing taken out of it, and `SidebarView`,
/// which is where the one `onMove` lives.
enum SidebarPaneRow: Identifiable {
    case project(SidebarRepoGroup)
    /// The project's name travels with the row, because a flat pane cannot say which project a row
    /// is under and so the row has to say it itself. See `SidebarWorkspaceRow`.
    case workspace(Workspace, projectName: String)
    /// The sentence that stands where a project's rows would be when it has none.
    case notice(repoID: RepoID)

    /// Prefixed by kind, because a project and its notice would otherwise share an id.
    var id: String {
        switch self {
        case .project(let group): "project:" + group.id.rawValue
        case .workspace(let workspace, _): "workspace:" + workspace.id
        case .notice(let repoID): "notice:" + repoID.rawValue
        }
    }

    /// The same row with nothing drawable left in it, which is all the reordering needs to know.
    var identity: SidebarReorder.Row {
        switch self {
        case .project(let group): .project(group.id)
        case .workspace(let workspace, _): .workspace(id: workspace.id, projectID: workspace.repoID)
        case .notice(let repoID): .notice(projectID: repoID)
        }
    }

    /// Flattens the groups into the run the list draws.
    ///
    /// A folded project contributes its own row and nothing else, which is what makes folding a
    /// change of the rows rather than of a section's state, and is why a collapsed project can
    /// still be dragged: it is one row that carries everything under it.
    static func rows(_ groups: [SidebarRepoGroup]) -> [SidebarPaneRow] {
        var rows: [SidebarPaneRow] = []
        for group in groups {
            rows.append(.project(group))
            guard !group.repo.collapsed else { continue }
            if group.workspaces.isEmpty {
                rows.append(.notice(repoID: group.id))
            } else {
                rows.append(
                    contentsOf: group.workspaces.map { .workspace($0, projectName: group.repo.name) }
                )
            }
        }
        return rows
    }
}
