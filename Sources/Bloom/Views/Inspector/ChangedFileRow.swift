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
            && lhs.isViewed == rhs.isViewed
            && lhs.fullPath == rhs.fullPath
            && lhs.supportsLocalFileActions == rhs.supportsLocalFileActions
            && lhs.depth == rhs.depth
            && lhs.supportsViewedMarks == rhs.supportsViewedMarks
            && lhs.supportsFileRevert == rhs.supportsFileRevert
    }

    var file: ChangedFile
    var isSelected: Bool
    /// Whether this file has been read, at the diff it has now. A tick and a quieter row, which
    /// is the whole point of the mark: the first version of this feature could be set and was
    /// never visible anywhere except the control that set it. See `ReviewedFile`.
    var isViewed: Bool = false
    /// The file's location in the worktree, for the menu items that hand it to another app.
    var fullPath: String
    /// How many levels down the tree this row is drawn. Zero in the flat list, which is what
    /// leaves that shape with no indent and no guides while both shapes run this same row.
    var depth: Int = 0
    var onSelect: () -> Void
    var onRevert: () -> Void
    /// Opens this file as a page in the workspace's browser tab, and in the half a split opens.
    /// Only a page is offered them, which `LocalPageItems` decides. Closures rather than the
    /// model, so the row keeps comparing on its values alone: see `==` above.
    var onOpenPage: @MainActor () -> Void
    var onSplitPage: @MainActor (SplitAxis) -> Void
    /// Ticks the file, or takes the tick off. The wording of the item is `ReviewedMarkAction`'s,
    /// shared with the file bar's toggle.
    var onSetViewed: @MainActor (Bool) -> Void = { _ in }
    var supportsLocalFileActions = true
    var supportsFileRevert = true
    var supportsViewedMarks = true

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
                    // Read rows step back rather than disappear. The diff is still there and the
                    // reader may well come back to it; what the dimming says is "not this one" at
                    // a glance down the column, which is the question a pass through twenty files
                    // is actually asking. Never on a selected row, where the accent fill has
                    // already made the row the loudest thing in the list and dimming its name
                    // against that reads as unreadable rather than as quiet.
                    .opacity(isViewed && !isOnSelection ? InspectorLayout.viewedOpacity : 1)
                Spacer(minLength: Metrics.spacingSmall)
                if isViewed {
                    Image(systemName: "checkmark.circle.fill")
                        .font(Typo.micro)
                        .imageScale(.small)
                        .foregroundStyle(isOnSelection ? Palette.selectedEmphasizedText : Palette.positive)
                        .accessibilityLabel("Viewed")
                }
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
        .background { if supportsLocalFileActions { HoverQuickLook(url: URL(fileURLWithPath: fullPath)) } }
        // The real file, so a drop into Finder or an editor gets the document rather than a
        // sentence about where it lives. One file per drag: the list carries a single selection.
        .fileDrag(path: fullPath, isEnabled: supportsLocalFileActions)
        .contextMenu {
            // First, because it is the one item here about the reader's pass through the diff
            // rather than about handing the file to something else, and because it is the item
            // this menu is most often opened for during a review.
            if supportsViewedMarks {
                Button(ReviewedMarkAction(isViewed: isViewed).title) { onSetViewed(!isViewed) }
                Divider()
            }
            if supportsLocalFileActions {
            OpenInItems(target: .file(fullPath))
            Button("Reveal in Finder") { Reveal.inFinder(fullPath) }
            // With the two above rather than beside Copy path: all of them hand this row to
            // something that opens it, and only the last is about the clipboard. The same grouping
            // `FileTreeRow` puts `Open Terminal Tab Here` in.
            LocalPageItems(path: fullPath, open: onOpenPage, split: onSplitPage)
            }
            Button("Copy path", action: copyPath)
            if supportsFileRevert {
            Divider()
            Button("Revert this file", role: .destructive, action: onRevert)
            }
        }
        .help(file.path)
        .accessibilityInputLabels([file.filename])
        .accessibilityValue(isViewed ? "Viewed" : "")
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
