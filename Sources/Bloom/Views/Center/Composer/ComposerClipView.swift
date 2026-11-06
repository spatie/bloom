import AppKit

/// Clips only while the draft is taller than the box. Dictation draws its glow as a subview of
/// the text view, and a clip view one line tall cut it in half.
final class ComposerClipView: NSClipView {
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateClipping()
    }

    override func viewFrameChanged(_ notification: Notification) {
        super.viewFrameChanged(notification)
        updateClipping()
    }

    private func updateClipping() {
        clipsToBounds = (documentView?.frame.height ?? 0) > bounds.height + 0.5
    }
}
