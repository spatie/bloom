import SwiftUI
import BloomCore

/// One quick prompt in the panel: its mark, its name, the first stretch of its words, and the
/// pencil that opens it for editing.
///
/// The same shape as `WorkspaceSourceRow` and `FileMentionRow`, deliberately: they are all the same
/// thing, a filtered floating list somebody arrows through, and a second idiom for the third one is
/// how a window grows three.
///
/// **The pencil is on the hovered row or the highlighted one**, so arrowing down with the keyboard
/// reveals it as surely as the pointer does. It is not a `\u{22EF}` menu: editing has one
/// destination, and reaching a menu with the pointer also moves the keyboard highlight, so an
/// `NSMenu` over a live popover would be an argument about which of the two owns the next click.
struct QuickPromptRow: View {
    var prompt: QuickPrompt
    var isSelected: Bool
    var onPick: @MainActor () -> Void
    var onHover: @MainActor () -> Void
    var onEdit: @MainActor () -> Void
    var onDelete: @MainActor () -> Void

    @Environment(\.controlActiveState) private var activeState

    @State private var isHovered = false

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: Metrics.spacing) {
                // Larger than the glyph column the one line lists use, and deliberately. This row
                // is two lines tall, and `Metrics.glyph` beside it read as a speck someone had
                // dropped rather than as the mark that tells five prompts apart at a glance, which
                // is the whole job the icon was added for.
                Image(systemName: QuickPrompt.resolvedSymbol(prompt.symbol))
                    .imageScale(.large)
                    .foregroundStyle(isEmphasized ? Palette.selectedEmphasizedText : Palette.textSecondary)
                    .frame(width: Metrics.repoIcon, height: Metrics.repoIcon)

                VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                    Text(prompt.resolvedName)
                        .font(Typo.body)
                        .foregroundStyle(isEmphasized ? Palette.selectedEmphasizedText : Palette.textPrimary)
                        .lineLimit(1)

                    // The words themselves, so a name chosen badly six weeks ago is still
                    // recoverable from the row. Absent when the prompt has no name of its own,
                    // because then the line above IS the preview and the row said it twice.
                    if prompt.hasSeparatePreview {
                        Text(prompt.preview)
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

                // The space is always taken, and only the pencil comes and goes. Shown and hidden
                // by presence, a name long enough to need the room lost forty points of it the
                // moment the row was arrowed onto: the text reflowed into an ellipsis under the
                // highlight and back out again as it left, on every press of Down.
                pencil
                    .opacity(isHovered || isSelected ? 1 : 0)
                    .allowsHitTesting(isHovered || isSelected)
            }
            .padding(.horizontal, Metrics.spacing)
            // Four points was what a one line row takes, and this one is two lines: the name sat
            // hard against the top of the selection with its ascenders touching the fill.
            .padding(.vertical, Metrics.spacingWide)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(prompt.resolvedName)
        .accessibilityValue(prompt.preview)
        // Focused, for the reason spelled out on `SlashCommandRow`: this list really is driven by
        // the arrow keys, which is the one case AppKit paints in the accent.
        .rowBackground(isSelected: isSelected, isHovered: isHovered, isFocused: true)
        .onHover { hovering in
            isHovered = hovering
            if hovering { onHover() }
        }
        // A free accelerator for anybody who tries it. Nothing depends on it being discovered: the
        // pencil above is the affordance, and the form it opens owns Delete.
        .contextMenu {
            Button("Edit", action: onEdit)
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    /// A button inside the row's own button, which AppKit resolves the way it looks: a click on the
    /// pencil edits, a click anywhere else on the row inserts.
    private var pencil: some View {
        Button(action: onEdit) {
            Image(systemName: "pencil")
                .imageScale(.small)
                .foregroundStyle(
                    isEmphasized
                        ? Palette.selectedEmphasizedText.opacity(0.85)
                        : Palette.textTertiary
                )
                .frame(width: Metrics.rowHeight - Metrics.spacingWide,
                       height: Metrics.rowHeight - Metrics.spacingWide)
                .background {
                    RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                        .fill(isEmphasized ? Palette.selectedEmphasizedText.opacity(0.18) : Palette.hover)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Edit this quick prompt")
        .accessibilityLabel("Edit \(prompt.resolvedName)")
    }

    /// Whether the row is about to be painted with the accent colour. The labels set their own
    /// colour, so the inverted foreground `rowBackground` installs never reaches them on its own.
    private var isEmphasized: Bool {
        isSelected && activeState != .inactive
    }
}
