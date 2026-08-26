import SwiftUI
import AppKit
import BloomCore

/// A folder in the changed files tree, said once for a whole chain of directories that only ever
/// had one child.
///
/// A folder is never selected, only opened, so this row carries no selection fill of its own. It
/// still reads `isOnEmphasizedSelection` because the hover fill and the tree's own row background
/// modifier put a foreground into the environment that the chevron and the name inherit.
///
/// Deliberately laid out exactly like `FileTreeRow`, the other tree in the same pane: one glyph
/// box, then the name. The two used to disagree about the glyph, the gap and the type size, which
/// made switching tabs look like switching apps.
struct ChangedFolderRow: View, Equatable {
    /// On the values, not on `action`, which is a fresh closure on every pass over the tree. See
    /// `ChangedFileRow` for the whole of the reason.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name
            && lhs.path == rhs.path
            && lhs.isExpanded == rhs.isExpanded
            && lhs.depth == rhs.depth
            && lhs.fullPath == rhs.fullPath
    }

    var name: String
    var path: String
    var isExpanded: Bool
    /// How many levels down the tree this row is drawn.
    var depth: Int
    /// The folder's location in the worktree, for the menu items that hand it to another app.
    var fullPath: String
    var action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: InspectorLayout.gap) {
                // One chevron turned rather than two symbols swapped, and on its own `.animation`
                // rather than the list's transaction, exactly as `FileTreeRow` does it: the two
                // trees share a pane and a folder opening must look the same in both.
                Image(systemName: "chevron.right")
                    .font(Typo.micro)
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(
                        TreeDisclosureMotion.chevron(reduceMotion: reduceMotion).animation,
                        value: isExpanded
                    )
                    .frame(width: InspectorLayout.glyphWidth, alignment: .leading)
                    .accessibilityHidden(true)
                // The same size as the files under it, one step quieter, and said hierarchically
                // so it still inverts if the row is ever drawn on a fill. It used to be two rungs
                // down the scale, which read as a section header rather than as a row of the
                // same rank as the ones it sits between.
                Text(name)
                    .font(Typo.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
            }
            .treeIndent(depth: depth)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Reveal in Finder") { Reveal.inFinder(fullPath) }
            OpenInItems(target: .folder(fullPath))
            Button("Copy path", action: copyPath)
        }
        .help(path)
        .accessibilityLabel(name)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityInputLabels([name])
    }

    private func copyPath() {
        Clipboard.copy(path)
    }
}
