import SwiftUI
import BloomCore

/// One quick prompt in the panel: its mark, its name, the first stretch of its words, whatever it
/// does beyond writing into the box, and the pencil that opens it for editing.
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

    @State private var isHovered = false

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: Metrics.spacingWide) {
                // Larger than the glyph column the one line lists use, and deliberately. This row
                // is two lines tall, and `Metrics.glyph` beside it read as a speck someone had
                // dropped rather than as the mark that tells five prompts apart at a glance, which
                // is the whole job the icon was added for.
                // `QuickPromptMarkView` rather than an `Image`, because the mark is an SF Symbol
                // on most rows and an emoji on some, and the two are not the same size at the same
                // point size. See its own note.
                QuickPromptMarkView(stored: prompt.symbol, points: Metrics.repoIcon)

                VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                    Text(prompt.resolvedName)
                        // `label` and not `body`: the scale's own note calls this rung the
                        // workhorse for row labels and anything scanned rather than read, which is
                        // what a menu row is. At `body` the panel was set a rung above the controls
                        // it hangs off. `FileMentionRow` and `SlashCommandRow` are on this rung.
                        .font(Typo.label)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)

                    // The words themselves, so a name chosen badly six weeks ago is still
                    // recoverable from the row. Absent when the prompt has no name of its own,
                    // because then the line above IS the preview and the row said it twice.
                    if prompt.hasSeparatePreview {
                        Text(prompt.preview)
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textTertiary)
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
        .accessibilityValue(
            // The quiet combination has no sentence of its own to read out, which is the same
            // reason the form no longer prints one under its switches.
            [prompt.preview, QuickPromptDelivery(prompt).sentence]
                .compactMap { $0 }
                .joined(separator: ". ")
        )
        // The labels above set no emphasized colour, and that is the other half of this decision.
        // They used to switch to white whenever the row was selected and the window was active,
        // which was right while the fill was the accent one and became white text on light grey the
        // moment it was not. The fill is always quiet now, so the text is always the ordinary ink.
        //
        // **The quiet fill, not the accent one**, and this is the one place in the composer's menus
        // that differs. `RowBackground` paints the accent when a list has the keyboard, and here it
        // has not: the keyboard is in the search field above, and the list is driven by arrows the
        // field hands down. More to the point, the top row is highlighted the instant the panel
        // opens, before anybody has done anything, and at full accent that reads as a row already
        // chosen rather than as the place Return will go. With one prompt in the list the fill
        // covered most of the panel.
        //
        // It is the treatment Spotlight, Raycast and Alfred all use for a resting first hit. Xcode's
        // Open Quickly is the one that fills it solid, and it is the outlier.
        .rowBackground(isSelected: isSelected, isHovered: isHovered, isFocused: false)
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

    // **The two delivery glyphs are gone**, and what they were for is worth writing down because
    // it was a real argument. A prompt with its switches on can send a turn the moment it is
    // chosen, and the panel's safety claim was that arrowing through a list cannot start one; a
    // chat mark and a paperplane at the trailing edge said so before the press. The owner has
    // looked at the row and asked for the pencil alone, so the sentence they stood for is carried
    // by the row's accessibility value and by the form the pencil opens, which is where the
    // switches are set in the first place. Three marks in a row of two lines was the complaint,
    // and it is a fair one: the pencil is the only one of the three that does anything.

    /// A button inside the row's own button, which AppKit resolves the way it looks: a click on the
    /// pencil edits, a click anywhere else on the row inserts.
    private var pencil: some View {
        Button(action: onEdit) {
            Image(systemName: "pencil")
                .imageScale(.small)
                .foregroundStyle(Palette.textTertiary)
                .frame(width: Metrics.rowHeight - Metrics.spacingWide,
                       height: Metrics.rowHeight - Metrics.spacingWide)
                // No plate. A filled square inside the selection made the row read as a card with
                // an action on it, and a menu on this Mac does not contain buttons. The glyph
                // alone, appearing only on the row you are on, is as far as this should go.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Edit this quick prompt")
        .accessibilityLabel("Edit \(prompt.resolvedName)")
    }
}
