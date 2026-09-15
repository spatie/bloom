import BloomCore

/// The run of rows the pane draws when it is grouped by status rather than by project.
///
/// The sections and which workspace is in which are `SidebarStatusListing`'s, in the core, where
/// they are tested. What is here is only the flattening into rows, which is the same shape
/// `SidebarPaneRow.rows` produces for the project view so that one `ForEach`, one selection and one
/// set of animations serve both.
///
/// There are no project headers in this shape, so a row says which project it belongs to itself:
/// its tile is drawn at the trailing edge rather than its mark's column being the project's. See
/// `WorkspaceRow.trailingRepo`.
enum SidebarStatusRows {
    /// - Parameter folded: the sections the owner has folded away. Only `idle` can be one, and it
    ///   still draws its heading and its count, so a folded section is never a section that has
    ///   quietly disappeared.
    /// - Parameter pending: the workspaces being cut right now, which belong under Working: a
    ///   worktree being made is the one thing happening that has no workspace row yet.
    static func rows(
        listing: SidebarStatusListing,
        projectName: (RepoID) -> String,
        folded: Set<SidebarStatusGroup>,
        crew: (WorkspaceID) -> [CrewRow] = { _ in [] },
        subagents: (WorkspaceID) -> [SubagentRow] = { _ in [] },
        pending: [PendingWorkspace] = [],
        showsSubagents: (WorkspaceID) -> Bool = { _ in true }
    ) -> [SidebarPaneRow] {
        var rows: [SidebarPaneRow] = []
        var sections = listing.sections

        // A create that has not landed yet has no `Workspace` to sort, so it is put in the section
        // it will join the moment it does. Building the section when there is none is deliberate:
        // the pane must not go quiet between asking for a workspace and the row arriving.
        if !pending.isEmpty, !sections.contains(where: { $0.group == .working }) {
            let insertion = sections.firstIndex { $0.group == .idle } ?? sections.count
            sections.insert(.init(group: .working, workspaces: []), at: insertion)
        }

        for section in sections {
            let waiting = section.group == .working ? pending : []
            let isFolded = folded.contains(section.group)
            rows.append(.statusHeading(
                section.group,
                count: section.workspaces.count + waiting.count,
                isFolded: isFolded
            ))
            guard !isFolded else { continue }

            for workspace in section.workspaces {
                rows.append(.workspace(workspace, projectName: projectName(workspace.repoID)))
                rows.append(contentsOf: crew(workspace.id).map {
                    .crew($0, workspaceID: workspace.id, repoID: workspace.repoID)
                })
                if showsSubagents(workspace.id) {
                    rows.append(contentsOf: subagents(workspace.id).map {
                        .subagent($0, workspaceID: workspace.id, repoID: workspace.repoID)
                    })
                }
            }
            rows.append(contentsOf: waiting.map { .pending($0) })
        }

        return rows
    }
}
