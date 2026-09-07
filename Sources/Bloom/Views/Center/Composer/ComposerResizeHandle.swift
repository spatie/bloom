import SwiftUI
import AppKit

/// A grip on the floating composer's top edge. It keeps the same drag, double-click reset,
/// and accessibility actions without drawing a divider across the conversation.
struct ComposerResizeHandle: View {
    /// How far the pointer has moved since this drag began, in points, positive downwards. What
    /// that means for the height is the composer's business, not this view's.
    var onDrag: @MainActor (CGFloat) -> Void
    var onDragEnd: @MainActor () -> Void
    /// Double click hands the composer back to sizing itself, the way double clicking a split view
    /// divider on this platform returns it to its default.
    var onReset: @MainActor () -> Void

    /// The grab strip, which is also the gap between the transcript and the composer box.
    static let height: CGFloat = Metrics.spacingWide

    /// One nudge of the VoiceOver adjustable action, in points. Roughly a line of body text, which
    /// is the unit the box grows in on its own.
    private static let step: CGFloat = 24

    @State private var isHovered = false
    @State private var isDragging = false
    @State private var isCursorPushed = false

    var body: some View {
        Color.clear
            .frame(width: 48)
            .frame(height: Self.height)
            .overlay {
                Capsule()
                    .fill(Palette.textTertiary)
                    .frame(width: 22, height: 3)
                    .opacity(isHovered || isDragging ? 0.65 : 0.25)
                    .allowsHitTesting(false)
            }
            .contentShape(.rect)
            .gesture(drag)
            .onTapGesture(count: 2, perform: onReset)
            .onHoverChange { hovering in
                isHovered = hovering
                updateCursor()
            }
            .onDisappear {
                isHovered = false
                isDragging = false
                updateCursor()
            }
            .accessibilityElement()
            .accessibilityLabel("Composer height")
            .accessibilityHint("Drag to resize. Double-click to fit the text.")
            .accessibilityAdjustableAction { direction in
                // Increment means a taller composer, and taller means dragging the top edge up,
                // which is negative in view coordinates. One nudge is one whole gesture, so the
                // end call is what lets the next nudge start from the new height.
                switch direction {
                case .increment: onDrag(-Self.step)
                case .decrement: onDrag(Self.step)
                @unknown default: return
                }
                onDragEnd()
            }
    }

    /// A minimum distance, so a double click reaches the tap gesture instead of being eaten as a
    /// zero length drag.
    private var drag: some Gesture {
        // `.global`: the default coordinate space is local to this handle, which moves as soon
        // as the height it is dragging changes, so the translation would be measured against an
        // origin it had just moved itself.
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                isDragging = true
                updateCursor()
                onDrag(value.translation.height)
            }
            .onEnded { value in
                onDrag(value.translation.height)
                isDragging = false
                updateCursor()
                onDragEnd()
            }
    }

    /// Pushed and popped rather than set, because AppKit restores the cursor whenever the pointer
    /// crosses a view with cursor rects, and the text view just below has one. The flag is what
    /// keeps the stack balanced: a push with no matching pop leaves the resize cursor on screen for
    /// the rest of the session. The cursor is held for the whole drag even once the pointer has
    /// left the strip, which is what dragging any other divider on this platform does.
    private func updateCursor() {
        let wanted = isHovered || isDragging
        guard wanted != isCursorPushed else { return }
        isCursorPushed = wanted
        if wanted {
            NSCursor.resizeUpDown.push()
        } else {
            NSCursor.pop()
        }
    }
}
