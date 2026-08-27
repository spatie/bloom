import SwiftUI

/// A footer picker whose rows carry their own sentence: the chip, and the panel it opens.
///
/// The sibling of `ComposerOptionMenu`, and the two are not a duplication. That one is a real
/// `NSMenu` and is what the model and the effort want: a menu is the platform's own control, it
/// costs nothing to draw, and rows called Opus 5 and Extra high have nothing to add underneath
/// themselves. This one is for the two pickers whose rows have a sentence to show before the
/// choice is made rather than after, which is the permission mode and the output style. The
/// visible difference between the two kinds of chip in one footer is the sentences, which is a
/// reason a reader can see.
///
/// The panel is `ComposerOptionList`; everything here is the chip and the popover around it.
struct ComposerOptionPicker: View {
    var options: [ComposerOption]
    var footnote: String?
    var selection: String
    var heading: String
    var systemImage: String
    var tint: Color = Palette.textSecondary
    /// Drops the word and keeps the glyph, for a footer that has run out of room. The tooltip and
    /// the accessibility label still say which picker this is, so nothing is lost but the width.
    var isCompact: Bool = false
    var help: String
    var onSelect: @MainActor (String) -> Void

    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen = true
        } label: {
            ComposerControlLabel(
                systemImage: systemImage,
                text: isCompact ? nil : label,
                tint: tint,
                isActive: isOpen,
                showsMenuIndicator: true
            )
        }
        .buttonStyle(.plain)
        // Vertically fixed only, which is the same give `ComposerOptionMenu` takes and for the
        // reason written there: a row of controls that all refuse to shrink overflows rather than
        // truncating, and in a split pane that took the model picker off one edge and the send
        // button off the other.
        .fixedSize(horizontal: false, vertical: true)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(label)
        // On the chip, not on the row around it. A popover anchors to the view it is attached to,
        // and `ComposerFooterView` learned that the expensive way with the quick prompt panel:
        // hoisted onto the footer it hung off the middle of the row with its arrow pointing at
        // whichever control happened to be at the centre. This chip is in all three widths of the
        // row, so it has nothing to be saved from by being hoisted.
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            ComposerOptionList(
                options: options,
                footnote: footnote,
                selection: selection,
                heading: heading,
                onSelect: onSelect,
                onClose: { isOpen = false }
            )
        }
    }

    private var label: String {
        ComposerOption.label(for: selection, in: options)
    }
}
