import Foundation

/// Whether Option+V means "mark this file as viewed" at the moment it is pressed.
///
/// **The whole of this type is about not stealing a keystroke from somebody typing.** Option+V is
/// a plain character on a Mac keyboard: it is how `√` is entered, a terminal reads it as a meta
/// key, and a key equivalent registered on a window is offered the event BEFORE the first
/// responder gets it. So a review pane with a composer under it, or a terminal in the pane beside
/// it, is a window where an unguarded shortcut swallows a character somebody meant to type. That
/// is a worse bug than not having the shortcut at all, because it is silent.
///
/// Two conditions, and both are about the window rather than about the review:
///
/// 1. **Nothing is taking text.** The app target asks the window who its first responder is and
///    whether it accepts typed characters, which covers the composer, the comment editors, the
///    in-place edit box, a rename field and the terminal alike, without this type having to know
///    that any of them exist.
/// 2. **There is a file to tick.** The review pane can be showing an empty state, a media preview
///    or a file that is no longer in the diff, and a shortcut that fires into one of those is a
///    keystroke that does nothing and says nothing.
///
/// Nothing here asks whether the review pane has the keyboard. It cannot: the pane is a
/// `ScrollView` of text and the keyboard is usually nowhere in particular, so requiring focus
/// would make the shortcut dead most of the time it is wanted. The rule that holds is the one
/// above: while a review is on screen and nobody is typing, the key is the review's.
public enum ReviewViewedShortcut {
    /// - Parameters:
    ///   - hasFile: whether the review is showing a changed file the mark can be put on.
    ///   - isTakingText: whether whatever holds the keyboard accepts typed characters.
    public static func isArmed(hasFile: Bool, isTakingText: Bool) -> Bool {
        hasFile && !isTakingText
    }
}
