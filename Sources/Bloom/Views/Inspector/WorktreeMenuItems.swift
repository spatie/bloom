import SwiftUI
import BloomCore

/// Everything the inspector's overflow menu offers about the worktree it is looking at.
///
/// Its own view, taking a `Workspace` and the pull request there may or may not be, rather than
/// the `WorkspaceModel` the toolbar holds. That is what lets the menu be built and photographed on
/// its own, which is the only account there is of what a menu says: on this macOS a tracking menu
/// is drawn out of process, `NSMenu.items` is empty while it is up, and `ImageRenderer` draws
/// SwiftUI's placeholder for one. `WorkspaceMenuItems` and `CenterPaneMenu` are the same shape for
/// the same reason. See `MenuProbe`.
///
/// Two groups. The first is about the worktree as a checkout: its branch, where it is on disk, and
/// what can open it. The second is about the pull request that checkout has, and is absent rather
/// than greyed when there is not one, because a workspace with no branch pushed anywhere has no
/// disabled state worth showing.
struct WorktreeMenuItems: View {
    var workspace: Workspace
    var pullRequest: PullRequest?

    var body: some View {
        Button("Copy Branch Name") { Clipboard.copy(workspace.branch) }
        Button("Reveal Worktree in Finder") { Reveal.inFinder(workspace.path) }
        OpenInItems(target: .folder(workspace.path), noun: "Worktree")

        if let pullRequest {
            Divider()
            Button("Open Pull Request") { GitHubBridge.open(pullRequest.url) }
            if let url = URL(string: pullRequest.url) {
                // Here rather than in the pull request strip above. That strip already clips at
                // the pane's narrow widths, and one more control in it buys discoverability with
                // the merge button's room.
                //
                // A `ShareLink` rather than a button that presents a picker of its own, so the
                // services open as a submenu of the menu the reader is already in, which is where
                // Finder puts Share. Labelled with a `Text` rather than a title string, because
                // the `.labelStyle(.iconOnly)` on the menu reaches its contents too and would
                // leave this item as a bare glyph.
                ShareLink(item: url) { Text("Share pull request") }
            }
        }
    }
}
