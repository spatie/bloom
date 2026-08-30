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

    /// Drawn in `SidebarReorder.drawn`'s order, by calling it. This and `AppModel.workspaces(in:)`
    /// each used to restate the rule as their own two-clause comparator, which dropped the
    /// `createdAt` tiebreak, and Swift's sort is not stable: two rows tied on (pinned, sortOrder)
    /// could draw in one order while `SidebarReorder.destination` computed the drop against the
    /// other, landing a dragged row one off.
    /// - Parameter showingHidden: whether the projects the owner has hidden are in the list. The
    ///   rule and everything it means are `ProjectVisibility`, in the core, where the suite can
    ///   reach them; this only asks. Hidden projects keep their place in the order rather than
    ///   sinking to the bottom, so turning the switch on inserts rows and moves nothing.
    static func build(
        repos: [Repo],
        workspaces: [Workspace],
        filter: SidebarFilter,
        showingHidden: Bool
    ) -> [SidebarRepoGroup] {
        var byRepo: [RepoID: [Workspace]] = [:]
        for workspace in workspaces {
            byRepo[workspace.repoID, default: []].append(workspace)
        }

        return ProjectVisibility.listed(repos, showingHidden: showingHidden).map { repo in
            let all = byRepo[repo.id] ?? []
            let rows = SidebarReorder.drawn(all.filter(filter.accepts))
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
    /// One crew member of the workspace above it: an agent another agent started in the same
    /// worktree. Carries its workspace so the row knows what selecting it selects, and its project
    /// so the reordering can count it.
    ///
    /// Its own case beside `subagent` rather than a second kind of one, on `Crew`'s argument: the
    /// two have different lifetimes, different selections and different rows, and one case
    /// carrying both would make every reader of either ask which it had.
    case crew(CrewRow, workspaceID: WorkspaceID, repoID: RepoID)
    /// One subagent of the turn running in the workspace above it. Carries its workspace so the
    /// row knows what selecting it selects, and its project so the reordering can count it.
    case subagent(SubagentRow, workspaceID: WorkspaceID, repoID: RepoID)
    /// A workspace whose worktree is still being cut. See `PendingWorkspace`.
    case pending(PendingWorkspace)
    /// The sentence that stands where a project's rows would be when it has none.
    case notice(repoID: RepoID)

    /// Prefixed by kind, because a project and its notice would otherwise share an id.
    var id: String {
        switch self {
        case .project(let group): "project:" + group.id.rawValue
        case .workspace(let workspace, _): "workspace:" + workspace.id.rawValue
        // Not scoped by workspace, unlike the subagent below it: a crew member is a row in the
        // sessions table and its id is Bloom's own, unique across the app.
        case .crew(let row, _, _): "crew:" + row.id.rawValue
        // Scoped by workspace, because `task_id` is the CLI's and two workspaces running at once
        // are two CLIs with two id spaces.
        case .subagent(let row, let workspaceID, _):
            "subagent:" + workspaceID.rawValue + ":" + row.id.rawValue
        // The same prefix a workspace row uses, deliberately: the pending row and the stored row
        // it becomes carry one id, so giving them one identity is what makes the swap a row
        // changing rather than one row leaving and another arriving in its place.
        case .pending(let pending): "workspace:" + pending.id.rawValue
        case .notice(let repoID): "notice:" + repoID.rawValue
        }
    }

    /// The same row with nothing drawable left in it, which is all the reordering needs to know.
    var identity: SidebarReorder.Row {
        switch self {
        case .project(let group): .project(group.id)
        case .workspace(let workspace, _): .workspace(id: workspace.id, projectID: workspace.repoID)
        case .crew(_, _, let repoID): .crew(projectID: repoID)
        case .subagent(_, _, let repoID): .subagent(projectID: repoID)
        case .pending(let pending): .pending(projectID: pending.repoID)
        case .notice(let repoID): .notice(projectID: repoID)
        }
    }

    /// Flattens the groups into the run the list draws.
    ///
    /// A folded project contributes its own row and nothing else, which is what makes folding a
    /// change of the rows rather than of a section's state, and is why a collapsed project can
    /// still be dragged: it is one row that carries everything under it.
    ///
    /// - Parameter crew: the agents another agent started in each workspace, oldest first. A
    ///   closure for the same reason `subagents` is: a crew member's state moves while it works,
    ///   and the groups are rebuilt only when the workspaces, the projects or the filter move. See
    ///   `AppModel.crewRows`.
    /// - Parameter subagents: the children to draw under each workspace, in the order they were
    ///   spawned. A closure rather than a field on the group, because a subagent's row changes
    ///   about once a second while one is running and the groups are rebuilt only when the
    ///   workspaces, the projects or the filter move. See `AppModel.subagentRows`.
    /// - Parameter pending: the workspaces this project has been asked for whose worktree is still
    ///   being cut, drawn after its stored rows because that is where the row each one becomes
    ///   will land: a new workspace takes the next `sort_order` and is not pinned, so
    ///   `SidebarReorder.drawn` puts it last. A closure for the same reason as `subagents`, and
    ///   because a create is a change to neither the workspaces nor the projects nor the filter.
    ///   See `PendingWorkspace`.
    static func rows(
        _ groups: [SidebarRepoGroup],
        crew: (WorkspaceID) -> [CrewRow] = { _ in [] },
        subagents: (WorkspaceID) -> [SubagentRow] = { _ in [] },
        pending: (RepoID) -> [PendingWorkspace] = { _ in [] }
    ) -> [SidebarPaneRow] {
        var rows: [SidebarPaneRow] = []
        for group in groups {
            rows.append(.project(group))
            guard !group.repo.collapsed else { continue }
            let waiting = pending(group.id)
            // A project whose only row is one being cut is not a project with no workspaces, so
            // the notice stays away: "No workspaces yet" printed directly above the workspace
            // being made is the sentence answering itself.
            if group.workspaces.isEmpty, waiting.isEmpty {
                rows.append(.notice(repoID: group.id))
            } else {
                for workspace in group.workspaces {
                    rows.append(.workspace(workspace, projectName: group.repo.name))
                    // Above the turn's subagents, and the order is the lifetimes. A crew member
                    // stays until somebody archives the workspace; a subagent row is drawn from a
                    // stream and is gone minutes later. Rows that come and go belong at the
                    // bottom of the block, where their arriving and leaving does not push the
                    // rows somebody is aiming at.
                    rows.append(contentsOf: crew(workspace.id).map {
                        .crew($0, workspaceID: workspace.id, repoID: group.id)
                    })
                    // Directly after their workspace and in spawn order, which is what makes the
                    // reading right even though depth past one is drawn at the same indent. See
                    // `SubagentRow.rows`.
                    rows.append(contentsOf: subagents(workspace.id).map {
                        .subagent($0, workspaceID: workspace.id, repoID: group.id)
                    })
                }
                rows.append(contentsOf: waiting.map { .pending($0) })
            }
        }
        return rows
    }
}
