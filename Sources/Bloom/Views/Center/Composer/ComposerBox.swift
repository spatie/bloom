import SwiftUI

/// Only the conversation composer floats. Creation forms keep their inset field, and both
/// keep the background as the focus target so text selection still belongs to NSTextView.
struct ComposerBox: ViewModifier {
    @Binding var isFocused: Bool
    var isFloating = false
    /// Tints the box while a file is being dragged towards it. See `ComposerDropHint`.
    var dropHint: ComposerDropHint?
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.colorSchemeContrast) private var contrast

    /// Enough of the accent in the glass to say a file let go now will be attached here, little
    /// enough that the text on it keeps its contrast.
    private static let dropTint = 0.25

    private var isDropTarget: Bool { dropHint?.isShown == true }

    private var isRingVisible: Bool { isFocused && activeState.showsFocusRing }

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: isFloating ? ComposerLayout.corner : Metrics.corner,
            style: .continuous
        )
    }

    func body(content: Content) -> some View {
        let padded = content
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, Metrics.gutter)
            .padding(.bottom, isFloating ? Metrics.spacingWide : Metrics.gutter)
            .background {
                shape
                    .fill(isFloating ? Color.clear : Palette.surfaceSunken)
                    .contentShape(shape)
                    .onTapGesture { isFocused = true }
                    .accessibilityHidden(true)
            }

        if isFloating {
            padded
                // One material for the whole composer. Its controls keep their ordinary styles,
                // and completion menus are attached outside this modifier.
                .glassEffect(
                    .regular.tint(isDropTarget ? Palette.accent.opacity(Self.dropTint) : nil),
                    in: shape
                )
                .overlay {
                    shape.strokeBorder(focusColour, lineWidth: contrast == .increased ? 2 : 0.5)
                    .opacity(isRingVisible ? focusOpacity : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
        } else {
            padded
                .overlay {
                    shape.strokeBorder(Palette.border, lineWidth: Metrics.outline)
                        .allowsHitTesting(false)
                }
                .overlay {
                    if isDropTarget {
                        shape.fill(Palette.accent.opacity(Self.dropTint)).allowsHitTesting(false)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Metrics.corner + 1.5)
                        .strokeBorder(Palette.focusRing, lineWidth: 3)
                        .padding(-1.5)
                        .opacity(isRingVisible ? 1 : 0)
                        .allowsHitTesting(false)
                }
        }
    }

    private var focusColour: Color {
        contrast == .increased ? Palette.focusRing : Palette.textSecondary
    }

    private var focusOpacity: Double { contrast == .increased ? 1 : 0.2 }

}

extension View {
    func composerBox(
        isFocused: Binding<Bool>, dropHint: ComposerDropHint? = nil, isFloating: Bool = false
    ) -> some View {
        modifier(ComposerBox(isFocused: isFocused, isFloating: isFloating, dropHint: dropHint))
    }
}
