import SwiftUI

/// The card the composer sits in, and its focus ring.
///
/// The tap lives on the background rather than on the box, so a click inside the text view still
/// lands on the text view and only the padding acts as a focus target.
struct ComposerBox: ViewModifier {
    @Binding var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .padding(Metrics.gutter)
            .background {
                RoundedRectangle(cornerRadius: Metrics.corner)
                    .fill(Palette.surfaceRaised)
                    .onTapGesture { isFocused = true }
                    .accessibilityHidden(true)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.corner)
                    .stroke(
                        isFocused ? Palette.accent : Palette.border,
                        lineWidth: isFocused ? Metrics.hairline * 2 : Metrics.hairline
                    )
            }
            .shadow(
                color: isFocused ? Palette.accent.opacity(0.24) : .clear,
                radius: Metrics.cornerSmall
            )
    }
}

extension View {
    func composerBox(isFocused: Binding<Bool>) -> some View {
        modifier(ComposerBox(isFocused: isFocused))
    }
}
