import SwiftUI
import AppKit

/// A one line field that types into a list rather than into a document: the arrow keys and Return
/// belong to whatever it is filtering, and only the characters are its own.
///
/// An `NSTextField` rather than SwiftUI's `TextField`, for the reason `ComposerTextEditor` writes
/// down about the composer: a focused `TextField` swallows Return and both arrows inside its field
/// editor, so `onSubmit` and `onKeyPress` on the view around it never see the shape of the event.
/// The field editor asks its delegate first through `doCommandBySelector`, which is the one place
/// those keys can be taken before the caret moves, so that is where this sits. Nothing else here
/// is AppKit's: the text is SwiftUI's binding and the field keeps no state of its own.
struct MenuSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    /// The keys the list wants. Returning false hands the key back to the field editor, which is
    /// what leaves Tab moving the focus and Return doing whatever a field does with it when the
    /// list has nothing highlighted to press.
    var onKey: @MainActor (ComposerKey) -> Bool
    /// The left and right arrows, for a list laid out as a grid, given the step they mean.
    ///
    /// Its own way in rather than two more cases on `ComposerKey`, which is the enum of keys **the
    /// composer** has to answer for itself: every one of its seven handlers would have had to
    /// answer a question only the icon picker asks, and one of them answering it wrongly would
    /// have taken the caret out of a field somebody was typing in. Absent by default, so a field
    /// that says nothing keeps the arrows the field editor's.
    var onHorizontal: (@MainActor (Int) -> Bool)?

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.stringValue = text
        context.coordinator.takeFocus(field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.onKey = onKey
        context.coordinator.onHorizontal = onHorizontal
        context.coordinator.text = $text
        // Written on every pass, not just at `makeNSView`. The icon picker changes it when its tab
        // changes, and set once the Emojis tab was captioned "Search icons".
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
        // Only when it differs. Writing the value back on every pass would move the insertion
        // point to the end of the field mid word.
        if field.stringValue != text { field.stringValue = text }
        // Asked for again here, and it is not belt and braces: the panel is made before its window
        // exists, so the first attempt has nothing to be first responder in. The coordinator only
        // ever succeeds once, so a field somebody has since tabbed out of is left alone.
        context.coordinator.takeFocus(field)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onKey: onKey, onHorizontal: onHorizontal)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onKey: @MainActor (ComposerKey) -> Bool
        var onHorizontal: (@MainActor (Int) -> Bool)?
        /// Whether the keyboard has been claimed once already. The panel opens because somebody
        /// clicked the control it hangs off and the next thing they do is type, so it is claimed;
        /// claiming it again on a later pass would drag the caret back out of wherever they had
        /// put it.
        private var didFocus = false

        init(
            text: Binding<String>,
            onKey: @escaping @MainActor (ComposerKey) -> Bool,
            onHorizontal: (@MainActor (Int) -> Bool)?
        ) {
            self.text = text
            self.onKey = onKey
            self.onHorizontal = onHorizontal
        }

        /// On the next pass of the run loop, because a view being made or updated is not yet in
        /// the window that would have to hand the keyboard over.
        @MainActor
        func takeFocus(_ field: NSTextField) {
            guard !didFocus else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.didFocus, let window = field.window else { return }
                didFocus = window.makeFirstResponder(field)
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func control(
            _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
        ) -> Bool {
            if let onHorizontal {
                switch selector {
                case #selector(NSResponder.moveLeft(_:)): if onHorizontal(-1) { return true }
                case #selector(NSResponder.moveRight(_:)): if onHorizontal(1) { return true }
                default: break
                }
            }
            let key: ComposerKey? = switch selector {
            case #selector(NSResponder.moveUp(_:)): .up
            case #selector(NSResponder.moveDown(_:)): .down
            case #selector(NSResponder.insertNewline(_:)): .returnKey
            case #selector(NSResponder.cancelOperation(_:)): .escape
            case #selector(NSResponder.insertTab(_:)): .tab
            default: nil
            }
            guard let key else { return false }
            return onKey(key)
        }
    }
}
