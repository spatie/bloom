import Foundation

/// Where the window goes when a workspace is archived, and when it goes there.
///
/// The archive is optimistic on purpose: the row leaves the sidebar before a single byte moves,
/// because the decision has already been taken and `git worktree remove` walking a `node_modules`
/// is seconds of a window that otherwise looks broken. The window used to be left behind by that.
/// The row vanished at once and the centre column, the terminal and the inspector went on drawing
/// the workspace for another two or three seconds, until git had finished, so the app looked
/// frozen at precisely the moment it had already decided. Both halves move together now, and this
/// is the rule they both ask.
///
/// **Nothing here ever moves the window back.** An earlier attempt paired the optimistic visit to
/// Home with a return to the old selection when the disk refused, and that return is the suspected
/// trigger of the macOS 27 crash: Home's `List` was built and then immediately dismantled while
/// the inspector was still resizing. A refused archive puts the row back in the sidebar and says
/// why in an alert; where the window is sitting by then is where it stays.
///
/// It also answers the second question a slow archive raises. Cleanup runs for seconds, and
/// somebody who picks another workspace while it finishes must not be dragged to Home when it
/// does. The answer is the same one function: the window only leaves for a selection that is
/// about the workspace being archived, whether that is the workspace itself or one of its
/// children.
public enum ArchiveNavigation {

    /// Where the window should go when `id` is archived, or nil to leave it exactly where it is.
    ///
    /// `workspaceID` is the whole test, and it is the right one because a subagent and a crew
    /// member both answer with the workspace they belong to. Reading one of those while its
    /// workspace is archived leaves the window on a transcript of a worktree that is being
    /// deleted, so those go to Home too.
    ///
    /// Home rather than the archived reader. Archiving is not a request to read what was just
    /// archived, an archive that can be taken back offers Edit > Undo instead, and Home is where
    /// every unresolvable selection in this app lands.
    public static func destination(
        leaving selection: SidebarSelection, archiving id: WorkspaceID
    ) -> SidebarSelection? {
        guard selection.workspaceID == id else { return nil }
        return .home
    }
}
