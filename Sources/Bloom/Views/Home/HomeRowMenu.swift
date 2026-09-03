import SwiftUI
import BloomCore

/// The right click menu on a workspace, as Home offers it.
///
/// **The active case is no longer a copy.** It was one, deliberately and temporarily, with a note
/// here saying what to extract when the two were put back together. That extraction has happened:
/// it is `WorkspaceMenuItems`, and the sidebar draws from the same view, so one workspace cannot
/// answer differently depending on which list you right clicked in. Adding two items to the menu
/// is what forced it, which is what the note said would.
///
/// What is left here is the ARCHIVED case, which is genuinely Home's alone: the sidebar never
/// lists an archived workspace at all.
///
/// An archived workspace gets a different menu. Its worktree has been removed, so Open in Editor,
/// Reveal in Finder and Archive would all be pointing at a directory that is not there. What it
/// does get is the two things that are still possible, and they are deliberately two rather than
/// one: Open reads the transcript, which always works because the transcript is in the database,
/// and Restore rebuilds the worktree, which needs a branch that may have been deleted. See
/// `ArchivedWorkspaceView` for why conflating them would produce a menu item that fails on exactly
/// the rows somebody most wants.
struct HomeRowMenu: View {
    var row: HomeRow
    /// Raised to the list, which owns the one field that can be open at a time.
    var onRename: (WorkspaceID) -> Void
    /// Raised for the same reason renaming is: the confirmation belongs to the list, which is what
    /// stays on screen while it is up. A menu is gone by the time the sheet would appear.
    var onDelete: (Workspace) -> Void

    @Environment(AppModel.self) private var app

    private var workspace: Workspace { row.workspace }

    var body: some View {
        if row.isArchived {
            Button("Open") { app.openArchived(workspace) }
            Button("Restore Workspace") {
                Task { await app.restore(workspace) }
            }
            .disabled(app.restoring.contains(workspace.id))
            Divider()
            Button("Copy Branch Name") { Clipboard.copy(workspace.branch) }
            Divider()
            // The one irreversible thing this menu can do, so it is last, alone under a rule, and
            // it takes an ellipsis because it opens the confirmation rather than doing it. That
            // confirmation is `ArchiveDeletion`, which counts the chats, the transcript rows and
            // the review comments that would go: the same words whether the deletion is started
            // here or with the Delete key, because it is the same deletion.
            //
            // Home only. The sidebar never lists an archived workspace, and a live one has a
            // worktree that Archive is the way through. See this file's head.
            Button("Delete\u{2026}") { onDelete(workspace) }
        } else {
            WorkspaceMenuItems(workspace: workspace, onRename: onRename)
        }
    }
}
