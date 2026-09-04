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
    /// The type, for the one caller that is not a menu row.
    ///
    /// The search screen's field is the only thing on its screen and is set at the size a window's
    /// search field gets, where every other caller here is a line in a floating panel. Absent by
    /// default, so a panel keeps the system size it has always had.
    var font: NSFont?
    /// Shift+Tab. Its own way in rather than a case on `ComposerKey` for the reason `onHorizontal`
    /// gives above: that enum is the keys **the composer** answers, and every one of its seven
    /// handlers would have to answer a question only the search panel asks.
    var onBacktab: (@MainActor () -> Bool)?
    /// Backspace pressed with nothing in the field, which is how the search panel backs out of a
    /// mode. Only then: a Backspace with text in front of it belongs to the field editor, always.
    var onDeleteEmpty: (@MainActor () -> Bool)?
    /// The right arrow, with whether the caret was at the very end of the text. The panel pushes
    /// into a row with it from the end and leaves it to the caret anywhere else, and which of the
    /// two that is stays a rule in the core rather than a condition written here.
    var onRight: (@MainActor (Bool) -> Bool)?
    /// Bumped by a caller to select everything in the field, which is what a second press of the
    /// key that opened the panel does. A counter rather than a flag, because the same request
    /// arriving twice has to be honoured twice.
    var selectAllToken = 0

    func makeNSView(context: Context) -> NSTextField {
        let field = MenuSearchFieldView()
        field.onCommandReturn = { [weak coordinator = context.coordinator] in
            coordinator?.onKey(.commandReturn) ?? false
        }
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font ?? .systemFont(ofSize: NSFont.systemFontSize)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.stringValue = text
        context.coordinator.takeFocus(field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.onKey = onKey
        context.coordinator.onHorizontal = onHorizontal
        context.coordinator.onBacktab = onBacktab
        context.coordinator.onDeleteEmpty = onDeleteEmpty
        context.coordinator.onRight = onRight
        context.coordinator.text = $text
        // Written on every pass, not just at `makeNSView`. The icon picker changes it when its tab
        // changes, and set once the Emojis tab was captioned "Search icons".
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
        // Only when it differs. Writing the value back on every pass would move the insertion
        // point to the end of the field mid word.
        if field.stringValue != text { field.stringValue = text }
        // And the type, for the same reason the placeholder above is written here: a caller that
        // changes its font keeps the one the field was made with. It is the same class of bug the
        // line above was written to fix, one field along.
        let resolved = font ?? .systemFont(ofSize: NSFont.systemFontSize)
        if field.font != resolved { field.font = resolved }
        context.coordinator.selectAll(field, token: selectAllToken)
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
        var onBacktab: (@MainActor () -> Bool)?
        var onDeleteEmpty: (@MainActor () -> Bool)?
        var onRight: (@MainActor (Bool) -> Bool)?
        /// The last `selectAllToken` acted on, so a redraw with the same number does not drag the
        /// selection back over a word somebody has since started retyping.
        private var selectedToken = 0
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

        /// Selects everything, once per token.
        @MainActor
        func selectAll(_ field: NSTextField, token: Int) {
            guard token != selectedToken else { return }
            selectedToken = token
            // Only when the field has the keyboard. `selectText` takes first responder as a side
            // effect, and a panel that stole the caret back on a redraw would be a field nobody
            // could leave.
            guard field.window?.firstResponder === field.currentEditor() else { return }
            field.selectText(nil)
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
            if let onRight, selector == #selector(NSResponder.moveRight(_:)) {
                // Whether the caret is at the very end with nothing selected. Reading the event is
                // the app target's half; what "the end" then means is the caller's rule.
                let selection = textView.selectedRange()
                let atEnd = selection.length == 0
                    && selection.location == (textView.string as NSString).length
                if onRight(atEnd) { return true }
            }
            if let onBacktab, selector == #selector(NSResponder.insertBacktab(_:)) {
                if onBacktab() { return true }
            }
            if let onDeleteEmpty, selector == #selector(NSResponder.deleteBackward(_:)),
               textView.string.isEmpty {
                if onDeleteEmpty() { return true }
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

/// The field itself, which exists only to catch Cmd+Return.
///
/// A field editor turns most keys into a `doCommandBySelector`, which is where everything else
/// here is answered, and it turns Cmd+Return into nothing at all: the standard key bindings map
/// Option+Return to `insertNewlineIgnoringFieldEditor:` and leave the Command version unbound. A
/// key equivalent is offered to the key window's view tree before the menu bar, so a `Button` with
/// that shortcut somewhere in the panel would fire, but it would fire for a row the field has
/// already moved off. This is the one place the press and the state it is about are the same
/// moment.
final class MenuSearchFieldView: NSTextField {
    var onCommandReturn: (@MainActor () -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function, .numericPad])
        guard modifiers == .command,
              let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first,
              Int(scalar.value) == 0x0D,
              // Only while this field has the keyboard, or a panel left in the hierarchy would
              // answer a key aimed at whatever the user is really looking at.
              window?.firstResponder === currentEditor(),
              let onCommandReturn else {
            return super.performKeyEquivalent(with: event)
        }
        return onCommandReturn() ? true : super.performKeyEquivalent(with: event)
    }
}
