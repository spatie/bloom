import SwiftUI
import AppKit
import BloomCore

/// What the title bar says you are looking at: the project's mark, followed by the actions that
/// apply to the whole worktree.
///
/// It belongs to a workspace and to nothing else. `TitleBarStrip` leaves it out entirely on Home
/// and on Search, so this view is never asked to describe them.
///
/// The workspace's own name is not here. It is the window's title, one row up and a few
/// millimetres to the left, where it comes with the proxy icon that lets the worktree be dragged
/// out of the title bar and the path above it be reached with a Command-click. Repeating the name
/// here would have been the same word twice on one row.
///
/// The branch used to sit here as a chip, and the pull request strip repeats it, so the window
/// showed the same branch name twice above itself. The strip keeps it, since that is where the
/// pull request it belongs to lives, and the menu below carries the one thing the chip was still
/// good for: reading the branch name off the screen. The two are side by side now rather than
/// stacked, which makes the repetition more obvious rather than less.
///
/// The project's NAME is not here either, for the same reason and by the same test. The mark is a
/// real detected icon for most projects and a monogram of the name for the rest, the sidebar names
/// the project a few centimetres to the left, and the branch the workspace cuts from it is spelled
/// out immediately to the right, so the word was the third statement of one fact in one band. What
/// a word says that a mark does not is carried by the tooltip and by the accessibility label, so
/// nothing that could only be read is gone: a pointer on the mark still names the project, and
/// VoiceOver still announces it rather than the two letters on the tile.
///
/// It was a trailing toolbar item until the pull request strip took the trailing end of the title
/// bar; it now sits one place to the left of that strip, at the centre column's own edge. Nothing
/// about how it draws changed with the move, and a title bar accessory brings no background of its
/// own, so the glass a macOS 26 toolbar item would have put behind it is not a question any more.
/// See `TitleBarStrip`.
struct WindowTitleLabel: View {
    @Environment(AppModel.self) private var app

    let workspace: Workspace

    var body: some View {
        HStack(spacing: Metrics.spacing) {
            if let repo = app.repo(for: workspace) {
                // The same mark as the one in front of the project in the sidebar and in a
                // search result. It was a circle here and a rounded square there, which read
                // as two different things. The inline size, because it stands beside a small
                // control rather than heading anything.
                //
                // `RepoIcon` hides itself from VoiceOver everywhere else, on the grounds that
                // the project's name is always written beside it. Here it is not, so the mark
                // becomes an element of its own and says the name itself.
                RepoIcon(repo: repo, size: Metrics.repoIconSmall)
                    .accessibilityElement()
                    .accessibilityLabel("Project \(repo.name)")
                    .help(repo.name)
            }

            menu(for: workspace)
        }
        .fixedSize()
    }

    /// The three things you can do to a worktree from a title bar: open it, find it, and read its
    /// branch name off the screen.
    ///
    /// Pin and Archive are deliberately not here, and neither is lost. Both are on the workspace's
    /// own row, in the sidebar's context menu and in Home's, which is where a list of workspaces is
    /// acted on; Archive is also the Workspace menu's own item with its shortcut, and the sidebar
    /// row's hover button. This menu hangs off a mark in the title bar and belongs to the one
    /// workspace already open, so an item that reorders the list it is not in, and an item that
    /// closes the window's own subject, were the two least at home in it.
    ///
    /// No separators. Three items that are all "do something with this worktree" are one group,
    /// and a menu of three carrying two rules is a menu made of edges. The two that were here
    /// existed to fence off Pin and Archive, which are the two that have gone.
    ///
    /// Copy Branch Name is last because it is the odd one out: the other two open something
    /// somewhere else, and this one puts a string on the pasteboard.
    ///
    /// Drawn like the inspector's overflow menu, because it is the same kind of button one strip
    /// away.
    private func menu(for workspace: Workspace) -> some View {
        Menu {
            Button("Open in Editor") { Reveal.inEditor(workspace.path) }
            Button("Reveal in Finder") { Reveal.inFinder(workspace.path) }
            Button("Copy Branch Name") { copy(workspace.branch) }
        } label: {
            Label("More for this workspace", systemImage: "ellipsis.circle")
        }
        .labelStyle(.iconOnly)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More for this workspace")
    }

    private func copy(_ text: String) {
        Clipboard.copy(text)
    }
}
