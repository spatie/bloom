import SwiftUI
import AppKit

/// The resize arrow a divider wears while the pointer is on it, pushed and popped so that it
/// cannot outlive the divider.
///
/// `NSCursor.push()` and `pop()` are a stack, and the three dividers that used them wrote the pair
/// out by hand inside one `onHover`: push on the way in, pop on the way out. Both halves of that
/// can go wrong and both did.
///
/// A pane closes under the pointer. `Cmd+W` in a shell, or a clean `exit`, removes the divider
/// while it is hovered, so the exit event never arrives, the push is never matched, and the
/// pointer stays a resize arrow over the whole window until something else happens to push. The
/// other half is quieter: a bare `else` pops whether or not this view was the one that pushed, so
/// an exit with no matching entry takes somebody else's cursor off the stack.
///
/// The flag closes both. Nothing is pushed twice, nothing is popped that was not pushed, and the
/// removal is a pop like any other. It is the same shape `ComposerResizeHandle` already worked out
/// for itself and wrote the symptom down for; this is that, in one place, for the dividers that
/// did not have it.
///
/// Still `push`/`pop` rather than AppKit's cursor rects, which would be leak-proof by
/// construction. A cursor rect is dropped the moment the pointer crosses another view that has
/// one, and dragging a divider takes the pointer straight off it and onto the pane beside it, so
/// the arrow would vanish for the part of the gesture it exists for.
private struct ResizeCursor: ViewModifier {
    var cursor: NSCursor

    /// Whether this view is the one holding the top of the cursor stack.
    @State private var isPushed = false

    func body(content: Content) -> some View {
        content
            .onHoverChange { hovering in hold(hovering) }
            .onDisappear { hold(false) }
    }

    private func hold(_ wanted: Bool) {
        guard wanted != isPushed else { return }
        isPushed = wanted
        if wanted {
            cursor.push()
        } else {
            NSCursor.pop()
        }
    }
}

extension View {
    /// Wears `cursor` while the pointer is inside, and gives it back on the way out or on the way
    /// off screen. See `ResizeCursor` for what the by-hand version left on screen.
    func resizeCursor(_ cursor: NSCursor) -> some View {
        modifier(ResizeCursor(cursor: cursor))
    }
}
