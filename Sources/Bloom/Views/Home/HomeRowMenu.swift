import SwiftUI
import BloomCore

/// The right click menu on a workspace, as Home offers it.
///
/// **This is a second copy, deliberately, and it should not stay one.** The sidebar builds the
/// same menu inside `RepoSection.row(_:)`, and the two are now the same six items in the same
/// order because they are the same six things you can do to a workspace: it cannot be right that
/// the answer depends on which list you happened to right click in. They were split because the
/// sidebar's copy is inside a file another pair of hands was in at the time, and copying a menu is
/// cheaper to undo than a bad merge.
///
/// What to extract when the two are put back together: a `WorkspaceMenuItems` view taking
/// `workspace: Workspace` and one closure, `onRename: (String) -> Void`, and reading `AppModel`
/// from the environment as both sites already do. Everything else in the menu is either a free
/// function (`Reveal`, `Clipboard`) or a call on the model (`togglePinned`, `archive`), so the
/// rename is the only thing the two callers genuinely do differently: the sidebar writes an id
/// into a binding shared across its whole list, Home writes one into its own. Both sites then
/// become `.contextMenu { WorkspaceMenuItems(workspace: workspace) { renaming = $0 } }`, and the
/// archive confirmation stays where it already is, in `AppModel.archive`.
///
/// An archived workspace gets a different, shorter menu. Its worktree has been removed, so Open in
/// Editor, Reveal in Finder and Archive would all be pointing at a directory that is not there.
struct HomeRowMenu: View {
    var row: HomeRow
    /// Raised to the list, which owns the one field that can be open at a time.
    var onRename: (String) -> Void

    @Environment(AppModel.self) private var app

    private var workspace: Workspace { row.workspace }

    var body: some View {
        if row.isArchived {
            Button("Copy branch name") { Clipboard.copy(workspace.branch) }
        } else {
            Button("Open in Editor") { Reveal.inEditor(workspace.path) }
            Button("Reveal in Finder") { Reveal.inFinder(workspace.path) }
            Button("Copy branch name") { Clipboard.copy(workspace.branch) }
            Divider()
            Button(workspace.pinned ? "Unpin" : "Pin") {
                Task { await app.togglePinned(workspace) }
            }
            Button("Rename") { onRename(workspace.id) }
            Divider()
            // Straight through, with no dialog of its own, exactly as the sidebar's menu does it:
            // whether an archive needs confirming depends on what is uncommitted, what is running
            // and what GitHub says, and `AppModel.archive` is where all three come together.
            Button("Archive", role: .destructive) {
                Task { await app.archive(workspace) }
            }
        }
    }
}
