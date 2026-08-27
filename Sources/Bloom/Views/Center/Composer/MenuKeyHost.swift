import SwiftUI
import AppKit

/// The keyboard for a floating list that has no field to type into.
///
/// **A menu is arrowable, answers Return and answers Escape, and anything replacing one has to
/// be.** The composer's other panels get that for free: they are opened by typing, so the arrows
/// and Return arrive at the composer's own text view and are forwarded down as `ComposerKey`
/// (`MenuSearchField` does the same job for the panels that carry a search box). The pickers in
/// the footer are opened by clicking a chip, there is nothing to type into them, and a picker of
/// permissions that could only be used with the pointer would be a worse control than the
/// `NSMenu` it replaced.
///
/// So the panel takes the keyboard itself, with an `NSView` that accepts first responder and
/// nothing else. An `NSView` rather than `focusable()` and `onKeyPress` for the reason
/// `ListKeyboardHost` gives at greater length: focus here is not a decoration, it is the answer
/// to "where do the arrow keys go", and one first responder is the honest way to say it.
///
/// It is placed as a background, and `hitTest` answers nil, so every point over it belongs to the
/// row drawn above.
struct MenuKeyHost: NSViewRepresentable {
    /// What the panel does with a key. False hands it back to the responder chain, which is what
    /// leaves Command shortcuts and the menu bar alone.
    var onKey: @MainActor (ComposerKey) -> Bool

    func makeNSView(context: Context) -> MenuKeyHostView {
        let view = MenuKeyHostView()
        view.onKey = onKey
        return view
    }

    func updateNSView(_ view: MenuKeyHostView, context: Context) {
        view.onKey = onKey
        view.takeFocus()
    }
}

final class MenuKeyHostView: NSView {
    var onKey: @MainActor (ComposerKey) -> Bool = { _ in false }

    /// Whether the keyboard has been claimed once already. Claimed once and never again: the
    /// panel opens because somebody pressed the chip it hangs off, so the keys are its own from
    /// that moment, and asking a second time would drag them back from wherever they had since
    /// been put. `MenuSearchField.Coordinator` holds the same flag for the same reason.
    private var didFocus = false

    override var acceptsFirstResponder: Bool { true }

    /// Invisible to the mouse. It is the panel's background, so every point in it is under a row.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Here as well as in `updateNSView`, and this is the one that usually does it: a view being
    /// made by a representable is not yet in a window, and a popover's window arrives a beat
    /// later. This fires exactly when there is something to be first responder in.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        takeFocus()
    }

    func takeFocus() {
        guard !didFocus, let window else { return }
        didFocus = window.makeFirstResponder(self)
    }

    /// Escape is answered here rather than through `cancelOperation`, and that is not a
    /// preference: `cancelOperation` is an optional requirement of
    /// `NSStandardKeyBindingResponding` rather than a method on `NSResponder`, so there is nothing
    /// to override and nothing to call up to, and the key binding system only turns a key press
    /// into one of those selectors for a view that asked it to. A raw `keyDown` sees Escape first
    /// either way, which is what a first responder is for.
    override func keyDown(with event: NSEvent) {
        if let key = Self.key(for: event), onKey(key) { return }
        super.keyDown(with: event)
    }

    /// The one place an `NSEvent` is read. What each of these means is the panel's business and,
    /// below that, `MenuRows`'s.
    ///
    /// `.function` and `.numericPad` are subtracted before asking whether a modifier was held,
    /// which is the bug `ListKeyboardHost.key(for:)` documents: AppKit sets both on every arrow
    /// key, so a plain Down arrives carrying two flags and a test for "no modifiers" rejects the
    /// one key a list most has to answer.
    static func key(for event: NSEvent) -> ComposerKey? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function, .numericPad])

        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else {
            return nil
        }

        if modifiers == .command, Int(scalar.value) == 0x0D { return .commandReturn }
        guard modifiers.isEmpty else { return nil }

        switch Int(scalar.value) {
        case NSUpArrowFunctionKey: return .up
        case NSDownArrowFunctionKey: return .down
        // Return and the numeric keypad's Enter, which every Mac list treats alike.
        case 0x0D, 0x03: return .returnKey
        case 0x1B: return .escape
        case 0x09: return .tab
        default: return nil
        }
    }
}
