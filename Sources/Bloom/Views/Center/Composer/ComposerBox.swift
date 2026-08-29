import SwiftUI

/// The card the composer sits in, and its focus ring.
///
/// The tap lives on the background rather than on the box, so a click inside the text view still
/// lands on the text view and only the padding acts as a focus target.
struct ComposerBox: ViewModifier {
    @Binding var isFocused: Bool
    var fillsPanel = false

    /// See `ControlActiveState.showsFocusRing`: a ring belongs in the key window only.
    @Environment(\.controlActiveState) private var activeState
    /// A file is being dragged over the box. Said with the border rather than with a plate over
    /// the content, so the draft stays readable while the drop is being aimed.
    var isDropTarget: Bool = false

    /// What AppKit draws around a focused control. Not a token, because nothing else in Bloom
    /// draws a focus ring and a three point line is the ring's definition rather than a spacing
    /// choice.
    private static let ringWidth: CGFloat = 3

    /// Focused, and in the window the keys are going to.
    private var isRingVisible: Bool { isFocused && activeState.showsFocusRing }

    private var borderColour: Color {
        isDropTarget ? Palette.accent : Palette.border
    }

    private var borderWidth: CGFloat {
        isDropTarget ? Metrics.outline * 2 : Metrics.outline
    }

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, Metrics.gutter)
            // The main composer ends beside the sidebar's 32-point status bar. Its controls are
            // 28 points high, so two points below them puts both strips on the same centre line.
            // A wider bottom inset lifted the model label above the sidebar controls and made the
            // shared window footer look stepped.
            .padding(.bottom, fillsPanel ? Metrics.spacingTight : Metrics.gutter)
            .background {
                // Sunken rather than raised. `surfaceRaised` resolves to the same white as the
                // transcript above it, so the box read as a hairline drawn on nothing rather than
                // as somewhere to write. `surfaceSunken` is a step away from the content ground in
                // both appearances, which is the whole of what makes a field look like a field.
                background
            }
            .overlay {
                border
            }
            .overlay {
                // The ring sits outside the border rather than replacing it, in the colour macOS
                // reserves for focus. What was here before was an accent hairline plus an accent
                // drop shadow: a web focus glow wearing a Mac's border, and one that ignored the
                // system's focus ring colour entirely.
                focusRing
            }
    }

    @ViewBuilder private var background: some View {
        if fillsPanel {
            Rectangle()
                .fill(Palette.surfaceSunken)
                .onTapGesture { isFocused = true }
                .accessibilityHidden(true)
        } else {
            RoundedRectangle(cornerRadius: Metrics.corner)
                .fill(Palette.surfaceSunken)
                .onTapGesture { isFocused = true }
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var border: some View {
        if fillsPanel {
            if isDropTarget {
                VStack(spacing: 0) {
                    Rectangle().fill(borderColour).frame(height: borderWidth)
                    Spacer(minLength: 0)
                }
            }
        } else {
            RoundedRectangle(cornerRadius: Metrics.corner)
                .strokeBorder(borderColour, lineWidth: borderWidth)
        }
    }

    @ViewBuilder private var focusRing: some View {
        if !fillsPanel {
            RoundedRectangle(cornerRadius: Metrics.corner + Self.ringWidth / 2)
                .strokeBorder(Palette.focusRing, lineWidth: Self.ringWidth)
                .padding(-Self.ringWidth / 2)
                .opacity(isRingVisible ? 1 : 0)
        }
    }
}

extension View {
    func composerBox(
        isFocused: Binding<Bool>, isDropTarget: Bool = false, fillsPanel: Bool = false
    ) -> some View {
        modifier(
            ComposerBox(
                isFocused: isFocused,
                fillsPanel: fillsPanel,
                isDropTarget: isDropTarget
            )
        )
    }
}
