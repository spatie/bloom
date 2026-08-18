import SwiftUI
import AppKit
import BatonCore

/// What the toolbar says you are looking at: the project, followed by the actions that apply to
/// the whole worktree.
///
/// The workspace's own name is not here. It is the window's title, one row up and a few
/// millimetres to the left, where it comes with the proxy icon that lets the worktree be dragged
/// out of the title bar and the path above it be reached with a Command-click. Repeating the name
/// here would have been the same word twice on one row.
///
/// It is always present, even on Home, where it is one word. That began as a workaround, because
/// an empty principal item collapsed the flexible space that pins the trailing toggles to the
/// right, which `ToolbarSpacer(.flexible)` would now express directly on macOS 26. It stays
/// because controls that move as you navigate are worse than a redundant word.
///
/// The branch used to sit here as a chip, and the inspector's pull request strip repeats it a
/// centimetre lower, so the window showed the same branch name twice above itself. The inspector
/// keeps it, since that is where the pull request it belongs to lives, and the menu below carries
/// the one thing the chip was still good for: reading the branch name off the screen.
///
/// It draws its own swatch and spacing, so on macOS 26 the toolbar is told not to put a glass
/// background behind it. See `BatonWindowToolbar`.
struct WindowTitleLabel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let workspace = app.selectedWorkspace {
            HStack(spacing: Metrics.spacing) {
                if let repo = app.repo(for: workspace) {
                    // The same mark, at the same size, as the one in front of the project in the
                    // sidebar and in a search result. It was a circle here and a rounded square
                    // there, which read as two different things.
                    RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                        .fill(Color(hexString: repo.accent))
                        .frame(width: Metrics.swatch, height: Metrics.swatch)
                        .accessibilityHidden(true)
                    Text(repo.name)
                        .font(Typo.labelEmphasis)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                }

                menu(for: workspace)
            }
            .fixedSize()
        } else {
            Text(app.selection == .search ? "Search" : "Home")
                .font(Typo.labelEmphasis)
                .foregroundStyle(Palette.textSecondary)
        }
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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
