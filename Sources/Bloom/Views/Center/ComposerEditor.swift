import SwiftUI

/// The text of the next turn, plus the placeholder that sits under it.
///
/// The height used to be measured and applied here. It is now handed in, because the divider above
/// the composer feeds the same number and two sources for one frame have to be reconciled in one
/// place. That place is `ComposerView`, which owns the rule. What the wrapped text occupies is
/// still measured here, where the text is, and reported outwards.
struct ComposerEditor: View {
    @Binding var text: String
    @Binding var caret: Int
    @Binding var isFocused: Bool
    /// What to draw at, already clamped by the caller.
    var height: CGFloat
    var onContentHeightChange: @MainActor (CGFloat) -> Void
    var onKey: @MainActor (ComposerKey) -> Bool
    /// Files dropped or pasted onto the text. Handed straight through to the composer, which owns
    /// what an attachment is.
    var onAttach: @MainActor ([AttachmentSource]) -> Bool

    private static let placeholder = "Ask to make changes, @mention files, run /commands"

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                // `textPlaceholder`, not the tertiary label: they are different colours, and
                // the tertiary label at 26% is faint enough that the prompt hint read as a
                // rendering fault rather than as a hint.
                Text(Self.placeholder)
                    .font(Typo.body)
                    .foregroundStyle(Palette.textPlaceholder)
                    // The text view's own container inset, so the hint and the first character
                    // typed over it start on the same column.
                    .padding(.horizontal, ComposerTextEditor.textInset)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            ComposerTextEditor(
                text: $text,
                caret: $caret,
                isFocused: $isFocused,
                onHeightChange: onContentHeightChange,
                onKey: onKey,
                onAttach: onAttach
            )
            .frame(height: max(height, ComposerTextEditor.lineHeight))
        }
    }
}
