import SwiftUI
import AppKit
import BloomCore

/// What the title bar says you are looking at: the project, followed by the actions that apply to
/// the whole worktree.
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
                // as two different things. The inline size, because the label beside it is a
                // toolbar label rather than a heading.
                RepoIcon(repo: repo, size: Metrics.repoIconSmall)
                Text(repo.name)
                    .font(Typo.labelEmphasis)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
            }

            menu(for: workspace)
        }
        .fixedSize()
    }

    /// The sidebar's row menu, minus the two entries that cannot travel: renaming is the sidebar
    /// editing its own row in place, and archiving asks about the branch there. Archiving from
    /// here goes through the model instead, which applies the user's branch setting and raises the
    /// window's own confirmation when there is unsaved work at stake.
    ///
    /// Drawn like the inspector's overflow menu, because it is the same kind of button one strip
    /// away.
    private func menu(for workspace: Workspace) -> some View {
        Menu {
            Button("Copy Branch Name") { copy(workspace.branch) }
            Divider()
            Button("Open in Editor") { Reveal.inEditor(workspace.path) }
            Button("Reveal in Finder") { Reveal.inFinder(workspace.path) }
            Divider()
            Button(workspace.pinned ? "Unpin" : "Pin") {
                Task { await app.togglePinned(workspace) }
            }
            Divider()
            Button("Archive", role: .destructive) {
                Task { await app.archive(workspace) }
            }
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
