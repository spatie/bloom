import AppKit
import SwiftTerm

/// The find bar of whatever is in front, reached the way AppKit reaches one.
///
/// **Why it walks the chain rather than sending to nil.** `NSApp.sendAction(to: nil)` finds the
/// first responder that merely implements the selector, and in this window that is not always the
/// one that can act on it. The transcript's text views set `usesFindBar = false` deliberately,
/// because each holds a single paragraph, and an `NSTextView` in that state still answers
/// `performTextFinderAction(_:)` by doing nothing at all. Sending blind would therefore swallow
/// Cmd+F over a conversation instead of letting it fall through to the workspace search. The find
/// bar SwiftTerm draws is the other half of the same problem: while its field has the keyboard the
/// first responder is a field editor, so the terminal that owns the search is several steps up.
///
/// So the target is resolved rather than assumed: the nearest thing up the chain that genuinely
/// has a find interface, which today is a terminal or an editable `SourceEditor`. Anything else is
/// no answer, and `FindCommand` in the core decides what happens then.
///
/// **A menu item is the argument.** Both implementations read the action off the sender's tag,
/// which is how AppKit has always carried it, so the item exists to hold the tag rather than to be
/// drawn anywhere.
@MainActor
enum FindInPlace {
    /// Whether anything in front can find, which is the boolean `FindCommand` is asked with.
    static var isAvailable: Bool { target() != nil }

    /// Runs one of the find actions against the pane in front. False when nothing there can find,
    /// which is the caller's cue to do whatever the rule says instead.
    @discardableResult
    static func perform(_ action: NSTextFinder.Action) -> Bool {
        guard let target = target() else { return false }
        let item = NSMenuItem()
        item.tag = action.rawValue
        target.performTextFinderAction(item)
        return true
    }

    /// The nearest responder above the keyboard that has a find bar of its own.
    ///
    /// `keyWindow` rather than `mainWindow`: a sheet or a panel in front is where the keystroke
    /// was aimed, and a find sent past it to the window behind is a find nobody asked for.
    private static func target() -> NSResponder? {
        var responder = NSApp.keyWindow?.firstResponder
        while let current = responder {
            // SwiftTerm 1.19 implements `performTextFinderAction(_:)` and ships `MacFindBarView`,
            // and nothing in Bloom had ever asked for either, so Cmd+F in a shell threw the reader
            // out to the sidebar.
            if current is SwiftTerm.TerminalView { return current }
            // `usesFindBar` is exactly the question: `SourceEditor` turns it on for an editable
            // file and the transcript turns it off, and those are the two right answers.
            if let text = current as? NSTextView, text.usesFindBar { return text }
            responder = current.nextResponder
        }
        return nil
    }
}
