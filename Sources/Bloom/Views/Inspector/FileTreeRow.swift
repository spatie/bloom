import SwiftUI
import AppKit

/// One row of the worktree tree: a disclosure chevron or a document icon, the name, and a dot if
/// the agent touched it.
///
/// As with `ChangedFileRow`, the tree paints the selection fill and this row reads it back out of
/// the environment, which is the only way its own body can invert the marks that carry meaning.
struct FileTreeRow: View {
    var item: FileTreeRowItem
    var isExpanded: Bool
    var isChanged: Bool
    /// The node's location on disk, for the menu items that hand it to another app.
    var fullPath: String
    var action: () -> Void

    @Environment(\.isOnEmphasizedSelection) private var isOnSelection

    /// The dot marking a file the agent touched. Punctuation, not a badge.
    private static let changedDotSize: CGFloat = 5

    var body: some View {
        Button(action: action) {
            HStack(spacing: InspectorLayout.gap) {
                Image(systemName: symbol)
                    .font(Typo.micro)
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
                    .frame(width: InspectorLayout.glyphWidth)
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
            .padding(
                .leading,
                CGFloat(item.depth) * InspectorLayout.indentStep + InspectorLayout.gap
            )
            .padding(.trailing, InspectorLayout.gap)
            .frame(height: Metrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Folders included: dragging a directory out of a worktree is the same gesture in Finder,
        // and the provider carries whichever of the two this row is.
        .fileDrag(path: fullPath)
        .contextMenu {
            Button("Open in Editor") { Reveal.inEditor(fullPath) }
            Button("Reveal in Finder") { Reveal.inFinder(fullPath) }
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

    private var symbol: String {
        guard item.node.isDirectory else { return "doc" }
        return isExpanded ? "chevron.down" : "chevron.right"
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.node.path, forType: .string)
    }
}
