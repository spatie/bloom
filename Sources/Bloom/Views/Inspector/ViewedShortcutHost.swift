import SwiftUI
import AppKit
import BloomCore

/// Option+V, marking the file the review is showing as viewed, without ever taking the keystroke
/// off somebody who is typing.
///
/// **An `NSView` rather than a hidden `Button` carrying `.keyboardShortcut("v", modifiers:
/// .option)`, and it is a fix rather than a preference.** A key equivalent registered on a window
/// is offered the event before the first responder sees it, and Option+V is a plain character on
/// a Mac keyboard: it is how `√` is typed, and a terminal reads it as a meta key. A hidden button
/// would therefore swallow it out of the composer under this very pane, out of the comment editor
/// inside the diff, and out of a terminal in the pane beside it, silently. Disabling the button
/// while any of those is focused was the other way, and it means this view knowing about every
/// text control in the window, which is the list that goes stale.
///
/// So the question asked here is the honest one: **does whatever holds the keyboard take typed
/// characters?** `NSTextInputClient` is the protocol that answers it, and every text control in
/// this window conforms to it, the composer's `NSTextView`, a field editor, SwiftTerm's terminal
/// and the inspector's filter alike, without any of them being named. The decision itself is
/// `ReviewViewedShortcut`, in the core, where the suite can reach it; what is left here is asking
/// AppKit the two facts it needs.
///
/// `performKeyEquivalent` rather than a local `NSEvent` monitor, because a monitor is per process
/// and would fire for every window at once, while this is dispatched from the key window down its
/// own view tree and stops at the first view that answers. With two review panes split side by
/// side the first in the tree takes it, which is a real edge and the smaller of the two: the
/// alternative is both files being ticked by one keystroke.
struct ViewedShortcutHost: NSViewRepresentable {
    /// Whether there is a file to mark at all. False leaves the key to the responder chain.
    var hasFile: Bool
    var onToggle: () -> Void

    func makeNSView(context: Context) -> ViewedShortcutHostView {
        ViewedShortcutHostView()
    }

    func updateNSView(_ view: ViewedShortcutHostView, context: Context) {
        view.hasFile = hasFile
        view.onToggle = onToggle
    }
}

final class ViewedShortcutHostView: NSView {
    var hasFile = false
    var onToggle: () -> Void = {}

    /// Invisible to the mouse, the way `ListKeyboardHostView` is: this is a background of the
    /// diff, every point in it is over a row, and an `NSView` inside a hosting view hit-tests
    /// ahead of what SwiftUI draws itself.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Never the first responder. Taking focus would be taking it from the list, the text or the
    /// terminal that has it, which is the opposite of what this view is for.
    override var acceptsFirstResponder: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard Self.isViewedShortcut(event) else { return false }
        guard ReviewViewedShortcut.isArmed(hasFile: hasFile, isTakingText: isTakingText) else {
            return false
        }
        onToggle()
        return true
    }

    /// Option and `v`, and nothing else held.
    ///
    /// `charactersIgnoringModifiers` rather than `characters`, because with Option down the
    /// latter is `√` and comparing against that would be comparing against the very thing this
    /// must not consume. `.function` and `.numericPad` are subtracted for the reason
    /// `ListKeyboardHostView.key(for:)` gives: AppKit sets them on keys that have nothing to do
    /// with either, and a test for "only Option" fails on a flag the user never pressed.
    static func isViewedShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function, .numericPad])
        guard modifiers == .option else { return false }
        return event.charactersIgnoringModifiers?.lowercased() == "v"
    }

    /// Whether the keyboard is pointed at something that takes typed characters.
    ///
    /// The window's own first responder, so a text view in another pane counts and a text view in
    /// another window does not. `NSTextInputClient` is what every one of them conforms to; a text
    /// field answers through its field editor, which is the responder while it is being edited.
    private var isTakingText: Bool {
        guard let responder = window?.firstResponder else { return false }
        return responder is NSTextInputClient
    }
}
