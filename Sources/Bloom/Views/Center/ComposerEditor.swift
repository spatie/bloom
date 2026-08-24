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
    /// Backspace at the very start of the text, where what is to the left of the caret is the
    /// command chip rather than a character. Returns true when the composer took it.
    var onBackspaceAtStart: @MainActor () -> Bool = { false }
    /// Files dropped or pasted onto the text, with the stretch of the draft they should take the
    /// place of. Handed straight through to the composer, which owns what an attachment is.
    var onAttach: @MainActor ([AttachmentSource], NSRange) -> Bool
    /// The files this prompt is carrying, so the paths in the draft can be drawn as chips.
    var attachmentPaths: [String] = []
    /// A click on one of those chips.
    var onOpenAttachment: @MainActor (String) -> Void = { _ in }
    /// The pointer settling on one, which is what raises its card.
    var onHoverAttachment: @MainActor (String?) -> Void = { _ in }
    /// How a file that has finished copying gets into the text as an edit the text system can
    /// undo. See `ComposerEditorHandle`.
    var handle: ComposerEditorHandle?
    /// What an empty box says. A parameter rather than a constant because the create sheet asks a
    /// different question of the same box: there is no conversation yet to ask for changes to.
    var placeholder: String = ComposerEditor.chatPlaceholder
    /// What the field announces itself as, passed through to the text view. A parameter for the
    /// same reason `placeholder` is: the review comment field is this box too, and it used to
    /// announce itself as "Message".
    var accessibilityLabel: String = "Message"

    static let chatPlaceholder = "Ask to make changes, @mention files, run /commands"

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                // `textPlaceholder`, not the tertiary label: they are different colours, and
                // the tertiary label at 26% is faint enough that the prompt hint read as a
                // rendering fault rather than as a hint.
                Text(placeholder)
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
                accessibilityLabel: accessibilityLabel,
                onHeightChange: onContentHeightChange,
                onKey: onKey,
                onBackspaceAtStart: onBackspaceAtStart,
                onAttach: onAttach,
                attachmentPaths: attachmentPaths,
                onOpenAttachment: onOpenAttachment,
                onHoverAttachment: onHoverAttachment,
                handle: handle
            )
            .frame(height: max(height, ComposerTextEditor.lineHeight))
        }
    }
}
