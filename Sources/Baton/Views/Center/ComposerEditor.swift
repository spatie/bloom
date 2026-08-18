import SwiftUI

/// The text of the next turn, plus the placeholder that sits under it.
///
/// The measured height lives here rather than in `ComposerView`: nothing outside this view needs
/// to know how tall the text currently is, and keeping it local means a keystroke that grows the
/// box invalidates the box and not the whole composer.
struct ComposerEditor: View {
    @Binding var text: String
    @Binding var caret: Int
    @Binding var isFocused: Bool
    var onKey: @MainActor (ComposerKey) -> Bool

    private static let placeholder = "Ask to make changes, @mention files, run /commands"

    @State private var height: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(Self.placeholder)
                    .font(Typo.body)
                    .foregroundStyle(Palette.textTertiary)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            ComposerTextEditor(
                text: $text,
                caret: $caret,
                isFocused: $isFocused,
                onHeightChange: { height = $0 },
                onKey: onKey
            )
            .frame(height: max(height, ComposerTextEditor.lineHeight))
        }
    }
}
