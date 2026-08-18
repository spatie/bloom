import SwiftUI

/// The card the composer sits in, and its focus ring.
///
/// The tap lives on the background rather than on the box, so a click inside the text view still
/// lands on the text view and only the padding acts as a focus target.
struct ComposerBox: ViewModifier {
    @Binding var isFocused: Bool

    /// What AppKit draws around a focused control. Not a token, because nothing else in Bloom
    /// draws a focus ring and a three point line is the ring's definition rather than a spacing
    /// choice.
    private static let ringWidth: CGFloat = 3

    func body(content: Content) -> some View {
        content
            .padding(Metrics.gutter)
            .background {
                // Sunken rather than raised. `surfaceRaised` resolves to the same white as the
                // transcript above it, so the box read as a hairline drawn on nothing rather than
                // as somewhere to write. `surfaceSunken` is a step away from the content ground in
                // both appearances, which is the whole of what makes a field look like a field.
                RoundedRectangle(cornerRadius: Metrics.corner)
                    .fill(Palette.surfaceSunken)
                    .onTapGesture { isFocused = true }
                    .accessibilityHidden(true)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.corner)
                    .strokeBorder(Palette.border, lineWidth: Metrics.hairline)
            }
            .overlay {
                // The ring sits outside the border rather than replacing it, in the colour macOS
                // reserves for focus. What was here before was an accent hairline plus an accent
                // drop shadow: a web focus glow wearing a Mac's border, and one that ignored the
                // system's focus ring colour entirely.
                RoundedRectangle(cornerRadius: Metrics.corner + Self.ringWidth / 2)
                    .strokeBorder(Palette.focusRing, lineWidth: Self.ringWidth)
                    .padding(-Self.ringWidth / 2)
                    .opacity(isFocused ? 1 : 0)
            }
    }
}

extension View {
    func composerBox(isFocused: Binding<Bool>) -> some View {
        modifier(ComposerBox(isFocused: isFocused))
    }
}
