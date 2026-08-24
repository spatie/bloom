import SwiftUI
import AppKit
import BloomCore

/// One changed file: git's own status letter, the filename, and what it cost in lines.
///
/// The selection and hover fill is painted by the list, not here, so this row can read
/// `isOnEmphasizedSelection` and flip the colours that carry meaning. A row that sets the fill on
/// itself only puts that value into its own children's environment, never into its own body.
struct ChangedFileRow: View, Equatable {
    /// A row redraws when what it holds changes, and not because the closures beside it are new
    /// closures. Both are written at the call site as `{ ... }`, so they are freshly allocated on
    /// every pass over the list, and functions are never equal to one another: without this
    /// SwiftUI has to assume every row differs from the one it drew a moment ago, and the whole
    /// realised list is rebuilt whenever anything above it moves.
    ///
    /// Compared on the values, which is everything this row draws from. What the closures do is
    /// decided by the list from the same `file`, so two of them can never disagree about a row
    /// they both belong to.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.file == rhs.file
            && lhs.isSelected == rhs.isSelected
            && lhs.fullPath == rhs.fullPath
            && lhs.depth == rhs.depth
    }

    var file: ChangedFile
    var isSelected: Bool
    /// The file's location in the worktree, for the menu items that hand it to another app.
    var fullPath: String
    /// How many levels down the tree this row is drawn. Zero in the flat list, which is what
    /// leaves that shape with no indent and no guides while both shapes run this same row.
    var depth: Int = 0
    var onSelect: () -> Void
    var onRevert: () -> Void

    @Environment(\.isOnEmphasizedSelection) private var isOnSelection

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: InspectorLayout.gap) {
                glyph
                // No colour of its own: the list already set the row's foreground, and a pinned
                // label colour would stay dark on the accent fill.
                Text(file.filename)
                    .font(Typo.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Metrics.spacingSmall)
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
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .treeIndent(depth: depth)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The real file, so a drop into Finder or an editor gets the document rather than a
        // sentence about where it lives. One file per drag: the list carries a single selection.
        .fileDrag(path: fullPath)
        .contextMenu {
            OpenInItems(target: .file(fullPath))
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
                isOnSelection
                    ? Palette.selectedEmphasizedText.opacity(0.2)
                    : tint.opacity(InspectorLayout.tintOpacity),
                in: RoundedRectangle(cornerRadius: Metrics.cornerSmall)
            )
            .accessibilityLabel(Self.description(of: file.change))
    }

    /// Green on the accent fill is unreadable, so on a selected row the letter borrows the row's
    /// own foreground and lets its shape carry the meaning instead.
    private var tint: Color {
        guard !isOnSelection else { return Palette.selectedEmphasizedText }

        return switch file.change {
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
        Clipboard.copy(file.path)
    }
}
