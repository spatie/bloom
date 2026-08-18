import Foundation

/// The keys the composer has to answer for itself.
///
/// A menu is open on top of a text view that never loses first responder, so the arrow keys and
/// Return mean different things depending on what is on screen. The text view forwards the
/// question to the composer rather than deciding.
enum ComposerKey {
    case up
    case down
    case returnKey
    case commandReturn
    case escape
    case tab
}
