import Foundation

/// Whether the composer's text view should take the keyboard, or give it up, on this layout pass.
///
/// **The bug: select text in a browser pane, press Cmd+C, and nothing is copied.** The Edit menu's
/// Copy is a plain `copy:` down the responder chain and `WKWebView` answers it, so the only way
/// for the key to do nothing is for the page not to hold the keyboard by the time it is pressed.
/// It did not, and the composer is what took it back.
///
/// `ComposerTextEditor.updateNSView` re-asserts first responder whenever the focus binding says
/// the composer is focused and the text view is not the window's first responder. The binding
/// learns otherwise from `ComposerTextView.resignFirstResponder`, and that write is **deferred by
/// one turn of the main actor**, deliberately: a responder change can land in the middle of a
/// SwiftUI update and writing state there is how a view ends up fighting itself.
///
/// So there is a gap. A click into a browser page moves first responder to WebKit's content view
/// and schedules the composer's binding to go false a turn later, and any redraw inside that gap
/// reads a binding that still says true against a view that has already resigned, and pulls the
/// keyboard straight back. A window with an agent streaming into it redraws several times a second,
/// so the gap is always used. The page keeps drawing its selection, which is why the pane looks
/// like it still has the keyboard, and Cmd+C goes to a composer with nothing selected.
///
/// **The fix is to say that the view's own last word wins until the binding catches up**, which is
/// the rule `lastReportedCaret` already applies to the caret, in the same file, for the same
/// reason: a binding echoing the view back is not an instruction to the view.
public enum ComposerFocus {
    /// - Parameters:
    ///   - wantsFocus: what the focus binding says, which can be one turn out of date.
    ///   - holdsKeyboard: whether the text view is already the window's first responder.
    ///   - isReportingChange: whether the view has resigned or accepted first responder and that
    ///     change has not reached the binding yet. This is the gap above.
    public static func shouldTakeKeyboard(
        wantsFocus: Bool, holdsKeyboard: Bool, isReportingChange: Bool
    ) -> Bool {
        wantsFocus && !holdsKeyboard && !isReportingChange
    }

    /// Giving it up needs no such guard. It only ever runs on a binding that says "not focused"
    /// against a view that is still first responder, which is a real instruction from somewhere
    /// else in the window rather than an echo, and nothing in the app asks for the keyboard by
    /// asking for it to be taken away.
    public static func shouldGiveUpKeyboard(wantsFocus: Bool, holdsKeyboard: Bool) -> Bool {
        !wantsFocus && holdsKeyboard
    }
}
