import Foundation

/// The list Cmd+Return pushes into: one workspace's own menu, which is the menu the sidebar, Home
/// and the menu bar already offer on that row.
///
/// **Nothing new, and nothing that has to be listed at the top level.** Raycast opens an action
/// menu inside a result and Linear drills into sub lists; here the sub list already exists as
/// `WorkspaceMenuAction`, gated by `WorkspaceMenuSubject.allows`, so an archived workspace is
/// offered exactly what Home's menu offers it and the two cannot drift.
///
/// **Two of the Workspace menu's items are deliberately not reachable from here.** Colour is a
/// submenu of ten swatches rather than an action, so a row that ran it would have nothing to run;
/// and Merge is not a `WorkspaceMenuAction` at all, because landing a branch is published by the
/// pull request band for the workspace on screen and cannot be aimed at an arbitrary row. Both are
/// still in the Workspace menu and both are still reachable through `>`.
public enum SearchPanelActions {
    /// The rows for one workspace, in the order the row's own menu draws them.
    ///
    /// The order is `WorkspaceMenuItems`': what the checkout is, then what the row is, then the
    /// one that destroys it. Restore takes Archive's place on a workspace that has already been
    /// archived, which is what Home's shorter menu does.
    public static let order: [WorkspaceMenuAction] = [
        .openInEditor,
        .revealInFinder,
        .copyName,
        .copyBranchName,
        .pin,
        .unreadMark,
        .rename,
        .restore,
        .archive,
    ]

    /// What can be pressed against this workspace, as menu bar items so every row prints the same
    /// title and the same key the menu bar prints.
    public static func rows(for subject: WorkspaceMenuSubject) -> [SearchPanelCommandHit] {
        order
            .filter { subject.allows($0) }
            .map { SearchPanelCommandHit(item: MenuBarCatalogue[menuBarAction(for: $0)]) }
    }

    /// One section, headed by nothing: the pill in the field already names what is being acted on,
    /// and a heading repeating it would be the same words twice on one card.
    public static func sections(for subject: WorkspaceMenuSubject) -> [SearchPanelSection] {
        let rows = rows(for: subject)
        guard !rows.isEmpty else { return [] }
        return [SearchPanelSection(id: "actions", title: nil, rows: rows.map { .command($0) })]
    }

    /// The row in the table each of these items is, so the panel and the menu bar cannot word one
    /// action two ways or print two different keys for it.
    ///
    /// Switched over the whole enum rather than through a dictionary, so an item added to
    /// `WorkspaceMenuAction` has to be given a row here or the build fails.
    public static func menuBarAction(for action: WorkspaceMenuAction) -> MenuBarAction {
        switch action {
        case .archive: .archive
        case .restore: .restore
        case .openInEditor: .openInEditor
        case .revealInFinder: .revealInFinder
        case .copyBranchName: .copyBranchName
        case .rename: .renameWorkspace
        case .pin: .pin
        case .unreadMark: .unreadMark
        case .colour: .colour
        case .copyName: .copyName
        }
    }

    /// The other direction, for the app target's one switch that performs a row.
    public static func workspaceAction(for action: MenuBarAction) -> WorkspaceMenuAction? {
        WorkspaceMenuAction.allCases.first { menuBarAction(for: $0) == action }
    }
}
