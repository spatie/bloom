import SwiftUI
import AppKit

/// The divider between the transcript and the composer, and the only way to set the composer's
/// height by hand.
///
/// A hairline inside a grab strip rather than a bare hairline: one pixel is not a target. The strip
/// is exactly the gap the composer already left above its box, so the divider costs the layout
/// nothing and only adds the line that makes it findable.
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
            .frame(height: Self.height)
            .overlay(alignment: .top) { Hairline() }
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
        DragGesture(minimumDistance: 1)
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
