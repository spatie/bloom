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

                Text(source.name)
                    .font(Typo.body)
                    .foregroundStyle(nameColour)
                    .lineLimit(1)
                    .truncationMode(truncation)

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
            .frame(height: Metrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The verb is spoken even where the section heading carries it on screen, because a reader
        // arrowing down the list hears one row at a time and the heading is above all of them.
        .accessibilityLabel("\(source.verb) \(source.name)")
        .accessibilityValue(source.note ?? "")
        // Focused, for the reason spelled out on `SlashCommandRow`.
        .rowBackground(isSelected: isSelected, isHovered: isHovered, isFocused: true)
        .onHover { hovering in
            isHovered = hovering
            if hovering { onHover() }
        }
    }

    /// Which end of a long name is dropped, and the two answers are opposite.
    ///
    /// A branch loses its front: `feature/` and a colleague's login are the part everybody shares,
    /// and the end is what tells two of somebody's `patch-1`s apart. A pull request loses its
    /// tail, because it opens with the number it is referred to by out loud.
    private var truncation: Text.TruncationMode {
        switch source {
        case .pullRequest: .tail
        case .newBranch, .existingBranch: .head
        }
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
