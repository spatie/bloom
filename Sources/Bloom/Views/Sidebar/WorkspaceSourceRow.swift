import SwiftUI
import BloomCore

/// One row in the source picker: what it is, what it is called, and the note that says what
/// selecting it will actually do.
///
/// The same shape as `FileMentionRow`, deliberately. The two panels are the same thing (a filtered
/// floating list somebody arrows through), and a second shape for the second one is how a window
/// grows two idioms for one job.
struct WorkspaceSourceRow: View {
    var source: WorkspaceSource
    var isSelected: Bool
    var onPick: @MainActor () -> Void
    var onHover: @MainActor () -> Void

    @Environment(\.controlActiveState) private var activeState

    @State private var isHovered = false

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: Metrics.spacing) {
                Image(systemName: glyph)
                    .imageScale(.small)
                    .foregroundStyle(isEmphasized ? Palette.selectedEmphasizedText : Palette.textTertiary)
                    .frame(width: Metrics.glyph)

                VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                    Text(source.name)
                        .font(Typo.body)
                        .foregroundStyle(nameColour)
                        .lineLimit(1)
                        .truncationMode(truncation)

                    // Only a pull request has one, so the list is not uniformly two lines high.
                    // A branch with nothing to add would otherwise carry an empty line for the
                    // sake of a shape.
                    if let detail = source.detail {
                        Text(detail)
                            .font(Typo.caption)
                            .foregroundStyle(
                                isEmphasized
                                    ? Palette.selectedEmphasizedText.opacity(0.75)
                                    : Palette.textTertiary
                            )
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer(minLength: Metrics.spacingSmall)

                if let note = source.note {
                    Text(note)
                        .font(Typo.caption)
                        .foregroundStyle(
                            isEmphasized
                                ? Palette.selectedEmphasizedText.opacity(0.75)
                                : Palette.textTertiary
                        )
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, Metrics.spacing)
            .padding(.vertical, Metrics.spacingTight)
            // A minimum rather than a fixed height, because a pull request row carries a second
            // line and a branch row does not. Fixed, the second line was clipped.
            .frame(minHeight: Metrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The verb is spoken even though the tab carries it on screen, because a reader arrowing
        // down the list hears one row at a time and the tab strip is above all of them.
        .accessibilityLabel("\(source.verb) \(source.name)")
        .accessibilityValue([source.detail, source.note].compactMap { $0 }.joined(separator: ", "))
        // Focused, for the reason spelled out on `SlashCommandRow`.
        .rowBackground(isSelected: isSelected, isHovered: isHovered, isFocused: true)
        .onHover { hovering in
            isHovered = hovering
            if hovering { onHover() }
        }
    }

    /// Which end of a long name is dropped, and the two answers are opposite.
    ///
    /// A ref loses its front: `feature/` and a colleague's login are the part everybody shares,
    /// and the end is what tells two of somebody's `patch-1`s apart. A row drawn under a pull
    /// request number loses its tail instead, because it opens with the number it is referred to
    /// by out loud.
    ///
    /// Asked of the name rather than of the case, because which of the two a pull request row is
    /// now depends on what it knows: it is named after its head branch when gh answered with one,
    /// and falls back to its number and title when gh did not. See `WorkspaceSource.name`.
    private var truncation: Text.TruncationMode {
        source.name.hasPrefix("#") ? .tail : .head
    }

    private var glyph: String {
        switch source {
        case .pullRequest: "arrow.triangle.pull"
        case .existingBranch: "arrow.triangle.branch"
        case .newBranch: "plus.circle"
        }
    }

    /// A branch a workspace already has is drawn quieter than the rest, because selecting it does
    /// something else: it goes to that workspace rather than making one. The note beside it says
    /// which, and the two together are what a disabled row would have said while being unclickable
    /// for no reason anybody could see.
    private var nameColour: Color {
        if isEmphasized { return Palette.selectedEmphasizedText }
        return source.heldBy == nil ? Palette.textPrimary : Palette.textTertiary
    }

    /// Whether the row is about to be painted with the accent colour. Both labels set their own
    /// colour, so the inverted foreground `rowBackground` installs never reaches them on its own.
    private var isEmphasized: Bool {
        isSelected && activeState != .inactive
    }
}
