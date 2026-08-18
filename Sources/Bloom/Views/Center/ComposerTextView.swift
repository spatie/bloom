import AppKit

/// An `NSTextView` that offers each key press to the composer before typing it, and says when it
/// was resized or focused so the SwiftUI side can keep up.
final class ComposerTextView: NSTextView {
    var keyHandler: (@MainActor (NSEvent) -> Bool)?
    var onWidthChange: (@MainActor () -> Void)?
    var onFocusChange: (@MainActor (Bool) -> Void)?

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if changed { onWidthChange?() }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

    /// Without this the window's default button, or the field editor's own cancel handling, can
    /// swallow Escape before `keyDown` ever sees it.
    override func cancelOperation(_ sender: Any?) {
        // Handled in keyDown. Overridden so AppKit does not beep.
    }
}
