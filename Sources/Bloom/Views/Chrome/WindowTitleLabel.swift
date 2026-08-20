import SwiftUI
import AppKit
import BloomCore

/// What the title bar offers you to do to the whole worktree: one menu, at the centre column's
/// trailing edge.
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
/// The project is not here at all, neither its name nor its mark. The name went first, on the
/// grounds that the sidebar names the project a few centimetres to the left and the branch cut
/// from it is spelled out immediately to the right; the mark went for the same reason, since a
/// tile carrying two letters of a word already on screen twice is the same fact a fourth time. So
/// this view is the menu and only the menu, and the width of the chip is the width of that button
/// with `Metrics.inset` on either side of it.
///
/// Which leaves the menu as the one thing in the band that stands for the project, so the menu is
/// what has to say so. See `menu(for:)`.
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
        menu(for: workspace)
    }

    /// The three things you can do to a worktree from a title bar: open it, find it, and read its
    /// branch name off the screen.
    ///
    /// Pin and Archive are deliberately not here, and neither is lost. Both are on the workspace's
    /// own row, in the sidebar's context menu and in Home's, which is where a list of workspaces is
    /// acted on; Archive is also the Workspace menu's own item with its shortcut, and the sidebar
    /// row's hover button. This menu belongs to the one workspace already open, so an item that
    /// reorders the list it is not in, and an item that closes the window's own subject, were the
    /// two least at home in it.
    ///
    /// No separators. Three items that are all "do something with this worktree" are one group,
    /// and a menu of three carrying two rules is a menu made of edges. The two that were here
    /// existed to fence off Pin and Archive, which are the two that have gone.
    ///
    /// Copy Branch Name is last because it is the odd one out: the other two open something
    /// somewhere else, and this one puts a string on the pasteboard.
    ///
    /// It names the project, in the tooltip and to VoiceOver. The mark used to carry that, because
    /// `RepoIcon` hides itself from a screen reader everywhere else on the grounds that the name is
    /// always written beside it, and with the mark gone this button is the whole of the accessory
    /// that is not the pull request strip. A label of "More for this workspace" alone would leave
    /// the project out of this band's accessibility tree entirely and leave a pointer resting here
    /// with nothing to read, so the name comes along as "in <project>", which is how the sidebar
    /// phrases the same relation on its own buttons. A workspace whose project has gone keeps the
    /// short form rather than inventing a name for it.
    ///
    /// Drawn like the inspector's overflow menu, because it is the same kind of button one strip
    /// away.
    private func menu(for workspace: Workspace) -> some View {
        let title = app.repo(for: workspace)
            .map { "More for this workspace in \($0.name)" } ?? "More for this workspace"

        return Menu {
            Button("Open in Editor") { Reveal.inEditor(workspace.path) }
            Button("Reveal in Finder") { Reveal.inFinder(workspace.path) }
            Button("Copy Branch Name") { copy(workspace.branch) }
        } label: {
            Label(title, systemImage: "ellipsis.circle")
        }
        .labelStyle(.iconOnly)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(title)
    }

    private func copy(_ text: String) {
        Clipboard.copy(text)
    }
}
