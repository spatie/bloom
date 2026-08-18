import SwiftUI
import AppKit

/// A folder in the changed files tree, said once for a whole chain of directories that only ever
/// had one child.
///
/// A folder is never selected, only opened, so this row carries no selection fill of its own. It
/// still reads `isOnEmphasizedSelection` because the hover fill and the tree's own row background
/// modifier put a foreground into the environment that the chevron and the name inherit.
struct ChangedFolderRow: View {
    var name: String
    var path: String
    var isExpanded: Bool
    var indent: CGFloat
    /// The folder's location in the worktree, for the menu items that hand it to another app.
    var fullPath: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.spacingSmall) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(Typo.micro)
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
                    .frame(width: InspectorLayout.glyphWidth)
                    .accessibilityHidden(true)
                Image(systemName: "folder")
                    .font(Typo.micro)
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                // A folder is one step quieter than the files under it, said hierarchically so it
                // still inverts if the row is ever drawn on a fill.
                Text(name)
                    .font(Typo.micro)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
            }
            .padding(.leading, indent + InspectorLayout.gap)
            .padding(.trailing, InspectorLayout.gap)
            .frame(height: Metrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Reveal in Finder") { Reveal.inFinder(fullPath) }
            Button("Open in Editor") { Reveal.inEditor(fullPath) }
            Button("Copy path", action: copyPath)
        }
        .help(path)
        .accessibilityLabel(name)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityInputLabels([name])
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}
