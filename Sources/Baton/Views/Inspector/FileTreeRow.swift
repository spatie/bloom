import SwiftUI
import AppKit

/// One row of the worktree tree: a disclosure chevron or a document icon, the name, and a dot if
/// the agent touched it.
struct FileTreeRow: View {
    var item: FileTreeRowItem
    var isExpanded: Bool
    var isChanged: Bool
    var isSelected: Bool
    var isHovered: Bool
    /// The node's location on disk, for the menu items that hand it to another app.
    var fullPath: String
    var action: () -> Void

    /// The dot marking a file the agent touched. Punctuation, not a badge.
    private static let changedDotSize: CGFloat = 5

    var body: some View {
        Button(action: action) {
            HStack(spacing: InspectorLayout.tight * 2) {
                Image(systemName: symbol)
                    .font(Typo.micro)
                    .imageScale(.small)
                    .foregroundStyle(Palette.textTertiary)
                    .frame(width: InspectorLayout.glyphWidth)
                    .accessibilityHidden(true)
                Text(item.node.name)
                    .font(Typo.label)
                    .foregroundStyle(
                        item.node.isDirectory ? Palette.textSecondary : Palette.textPrimary
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if isChanged {
                    Circle()
                        .fill(Palette.warning)
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
        .rowBackground(isSelected: isSelected, isHovered: isHovered)
        .padding(.horizontal, InspectorLayout.tight * 2)
        .contextMenu {
            Button("Open in Editor") { Reveal.inEditor(fullPath) }
            Button("Reveal in Finder") { Reveal.inFinder(fullPath) }
            Button("Copy path", action: copyPath)
        }
        .help(item.node.path)
        .accessibilityInputLabels([item.node.name])
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
