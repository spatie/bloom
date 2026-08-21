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
        } else {
            WorkspaceMenuItems(workspace: workspace, onRename: onRename)
        }
    }
}
