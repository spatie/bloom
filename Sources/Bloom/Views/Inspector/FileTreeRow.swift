import SwiftUI
import AppKit
import BloomCore

/// One row of the worktree tree: a disclosure chevron or a document icon, the name, and a dot if
/// the agent touched it.
///
/// As with `ChangedFileRow`, the tree paints the selection fill and this row reads it back out of
/// the environment, which is the only way its own body can invert the marks that carry meaning.
struct FileTreeRow: View, Equatable {
    /// On the values, not on `action`, which is a fresh closure on every pass over the tree. See
    /// `ChangedFileRow` for the whole of the reason.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item.node == rhs.item.node
            && lhs.item.depth == rhs.item.depth
            && lhs.isExpanded == rhs.isExpanded
            && lhs.isChanged == rhs.isChanged
            && lhs.fullPath == rhs.fullPath
    }

    var item: FileTreeRowItem
    var isExpanded: Bool
    var isChanged: Bool
    /// The node's location on disk, for the menu items that hand it to another app.
    var fullPath: String
    var action: () -> Void
    /// Opens a shell in this row, which only a folder row offers. See `FolderTerminal`.
    var onOpenTerminal: () -> Void

    @Environment(\.isOnEmphasizedSelection) private var isOnSelection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The dot marking a file the agent touched. Punctuation, not a badge.
    private static let changedDotSize: CGFloat = 5

    var body: some View {
        Button(action: action) {
            HStack(spacing: InspectorLayout.gap) {
                Image(systemName: symbol)
                    .font(Typo.micro)
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
                    // One chevron turned rather than two symbols swapped, which is what a
                    // disclosure triangle on this platform does. Its own `.animation` and not the
                    // tree's transaction, so it still turns on an expansion too big for the rows
                    // below to travel. See `TreeDisclosureMotion`.
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(
                        TreeDisclosureMotion.chevron(reduceMotion: reduceMotion).animation,
                        value: isExpanded
                    )
                    .frame(width: InspectorLayout.glyphWidth, alignment: .leading)
                    .accessibilityHidden(true)
                // A directory is one step quieter than a file, said with the hierarchical style so
                // it still inverts on a selected row.
                Text(item.node.name)
                    .font(Typo.body)
                    .foregroundStyle(item.node.isDirectory ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if isChanged {
                    Circle()
                        .fill(isOnSelection ? Palette.selectedEmphasizedText : Palette.warning)
                        .frame(width: Self.changedDotSize, height: Self.changedDotSize)
                        .accessibilityLabel("Changed")
                }
            }
            .treeIndent(depth: item.depth)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Folders included: dragging a directory out of a worktree is the same gesture in Finder,
        // and the provider carries whichever of the two this row is.
        .fileDrag(path: fullPath)
        .contextMenu {
            // The one place a row is either kind, so the target is decided per row rather than
            // per view: a folder is not offered to something that only opens files, and a file is
            // not handed to a terminal.
            OpenInItems(target: item.node.isDirectory ? .folder(fullPath) : .file(fullPath))
            Button("Reveal in Finder") { Reveal.inFinder(fullPath) }
            // With the two above rather than beside Copy path: all three hand this row to
            // something that opens it, and only the last is about the clipboard. `canOpen` is
            // what keeps it off a file row, where the submenu above turns into Open File in, and
            // off a folder that is not on disk.
            if FolderTerminal.canOpen(folder: fullPath) {
                Button(FolderTerminal.menuTitle, action: onOpenTerminal)
            }
            Button("Copy path", action: copyPath)
        }
        .help(item.node.path)
        .accessibilityValue(disclosureState)
        .accessibilityInputLabels([item.node.name])
    }

    /// A file has no disclosure state to report, and an empty value is one VoiceOver skips.
    private var disclosureState: String {
        guard item.node.isDirectory else { return "" }
        return isExpanded ? "Expanded" : "Collapsed"
    }

    /// Always the closed chevron for a directory. Open is the same glyph, turned.
    private var symbol: String {
        item.node.isDirectory ? "chevron.right" : "doc"
    }

    private func copyPath() {
        Clipboard.copy(item.node.path)
    }
}
