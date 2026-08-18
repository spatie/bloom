import SwiftUI
import AppKit
import BatonCore

/// One changed file: git's own status letter, the filename, and what it cost in lines.
struct ChangedFileRow: View {
    var file: ChangedFile
    var isSelected: Bool
    var isHovered: Bool
    /// The file's location in the worktree, for the menu items that hand it to another app.
    var fullPath: String
    var onSelect: () -> Void
    var onRevert: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: InspectorLayout.gap) {
                glyph
                Text(file.filename)
                    .font(Typo.label)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: InspectorLayout.tight * 2)
                if file.isBinary {
                    Chip(text: "bin")
                } else {
                    DiffStatLabel(
                        additions: file.additions,
                        deletions: file.deletions,
                        compact: true
                    )
                }
                Image(systemName: isSelected ? "chevron.down" : "chevron.right")
                    .font(Typo.micro)
                    .imageScale(.small)
                    .foregroundStyle(Palette.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, InspectorLayout.gap)
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
            Divider()
            Button("Revert this file", role: .destructive, action: onRevert)
        }
        .help(file.path)
        .accessibilityInputLabels([file.filename])
    }

    /// The status letter git uses, so the list reads the same as `git status` does. The letter is
    /// carried by shape as well as colour, which is what keeps it readable with Differentiate
    /// Without Color turned on.
    private var glyph: some View {
        Text(file.change.rawValue)
            .font(Typo.codeTiny)
            .foregroundStyle(tint)
            .frame(width: InspectorLayout.glyphWidth, height: InspectorLayout.glyphWidth)
            .background(
                tint.opacity(InspectorLayout.tintOpacity),
                in: RoundedRectangle(cornerRadius: Metrics.cornerSmall)
            )
            .accessibilityLabel(Self.description(of: file.change))
    }

    private var tint: Color {
        switch file.change {
        case .added, .untracked: Palette.positive
        case .deleted: Palette.negative
        case .modified: Palette.warning
        case .renamed, .copied: Palette.accent
        }
    }

    private static func description(of change: ChangedFile.Change) -> String {
        switch change {
        case .added: "Added"
        case .untracked: "Untracked"
        case .deleted: "Deleted"
        case .modified: "Modified"
        case .renamed: "Renamed"
        case .copied: "Copied"
        }
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(file.path, forType: .string)
    }
}
