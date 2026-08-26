import Foundation

/// The workspace the Workspace menu acts on, which is not always the one the sidebar is pointing
/// at.
///
/// **The bug this is written from.** Every item in that menu was gated on
/// `AppModel.selectedWorkspace`, which is derived from `SidebarSelection.workspaceID`. On Home the
/// selection is `.home`, so a row highlighted in that list left Archive, Open in Editor, Reveal in
/// Finder and Copy Branch Name all greyed out while the user was looking straight at the thing
/// they name. Mail and Finder key their menus to whichever list holds the keyboard: select a
/// message in the search results and Delete, Move To and Get Info all act on it.
///
/// **The rule, and why the selection is asked first.** A sidebar selection that names a workspace
/// wins, because when the window is on a workspace the window is about that workspace. Only when
/// it names something that is not a workspace (Home) does the highlighted row in the list on
/// screen answer. In practice the two never both apply, because Home fills the centre column and
/// so cannot be on screen while a workspace is selected. The order is what makes that a guarantee
/// rather than a coincidence: a focused value that lingered a frame too long after a screen was
/// left can never redirect the menu at a row nobody can see.
public enum WorkspaceMenuSubject: Hashable, Sendable {
    /// A live workspace, with a worktree on disk.
    case live(WorkspaceID)
    /// One that has been archived: readable, restorable, and with nothing left on disk.
    case archived(WorkspaceID)

    /// The row a list has highlighted, published by whichever list is on screen.
    ///
    /// It carries `isArchived` rather than leaving the menu to look the id up, because Home lists
    /// both kinds in one table and the row itself is the only place that already knows which it
    /// is.
    public struct FocusedRow: Hashable, Sendable {
        public var id: WorkspaceID
        public var isArchived: Bool

        public init(id: WorkspaceID, isArchived: Bool) {
            self.id = id
            self.isArchived = isArchived
        }
    }

    public static func resolve(
        selection: SidebarSelection, focusedRow: FocusedRow?
    ) -> WorkspaceMenuSubject? {
        if let id = selection.workspaceID { return .live(id) }
        if let id = selection.archivedWorkspaceID { return .archived(id) }
        guard let focusedRow else { return nil }
        return focusedRow.isArchived ? .archived(focusedRow.id) : .live(focusedRow.id)
    }

    /// The workspace this names, whether or not it still has a worktree.
    public var id: WorkspaceID {
        switch self {
        case .live(let id), .archived(let id): id
        }
    }

    /// Set only when the worktree is still there, which is what the four items that touch the disk
    /// need to know.
    public var liveID: WorkspaceID? {
        if case .live(let id) = self { return id }
        return nil
    }

    public var archivedID: WorkspaceID? {
        if case .archived(let id) = self { return id }
        return nil
    }

    /// Whether an item may be pressed against this subject.
    ///
    /// One table rather than a condition per item, because the two lists that publish a row and the
    /// menu that reads one must not disagree about what an archived workspace can be asked to do.
    /// The archived answers are `HomeRowMenu`'s, which has drawn exactly this menu for archived
    /// rows since before the menu bar could reach them.
    public func allows(_ action: WorkspaceMenuAction) -> Bool {
        switch self {
        case .live:
            action != .restore
        case .archived:
            // Reading a branch name is the one thing that still means something once the worktree
            // is gone. Opening an editor or a Finder window on a path that is not there is not,
            // and neither is archiving what is already archived. Renaming is left out because
            // Home's own menu leaves it out: an archived row is a record rather than a workspace.
            action == .restore || action == .copyBranchName
        }
    }
}

/// The items in the Workspace menu that act on one workspace.
///
/// Setup, the run scripts and Stop Agent are not here: each needs a live `WorkspaceModel` rather
/// than a row, and what they can do is decided by that model rather than by which list is focused.
public enum WorkspaceMenuAction: String, Hashable, Sendable, CaseIterable {
    case archive
    case restore
    case openInEditor
    case revealInFinder
    case copyBranchName
    case rename
}
