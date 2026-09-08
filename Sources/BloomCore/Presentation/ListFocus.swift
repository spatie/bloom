import Foundation

/// How a list came to hold the keyboard, which is what decides whether it draws a focus ring.
///
/// The distinction exists because macOS itself makes it. An `NSTableView` clicked with the mouse
/// shows an emphasised selection and no ring; the ring is what a keyboard user gets, because for
/// them it is the only thing on screen saying where the next arrow key will land. A reader who
/// has just clicked a filename already knows: their pointer is on it.
public enum ListFocusOrigin: Sendable, Equatable {
    /// A click landed on a row, and the list took the keyboard as a consequence of it.
    case mouse
    /// Tab, a shortcut, or a key the list itself answered. The ring is for this reader.
    case keyboard
    /// Focus arrived with no event behind it at all, which is the restoring case. Treated as
    /// keyboard, because the ring is only ever wrong when a pointer is doing the work.
    case unknown
}

/// What a list knows about its own keyboard, and the one rule over it.
///
/// A value rather than two loose booleans in a view, because the rule is the whole point and a
/// rule in a view is a rule nothing can test. `hasKeyboard` still decides the emphasised selection
/// fill exactly as it always did; only the ring reads the origin.
public struct ListFocus: Sendable, Equatable {
    /// Whether the arrow keys move this list.
    public var hasKeyboard: Bool
    /// How it got them. Meaningless while `hasKeyboard` is false and never read there.
    public var origin: ListFocusOrigin
    /// Whether this Mac has Full Keyboard Access turned on, in which case every focusable thing
    /// draws its ring and a list is no exception: somebody who has asked the system for rings is
    /// asking for this one too.
    public var fullKeyboardAccess: Bool

    public init(
        hasKeyboard: Bool = false,
        origin: ListFocusOrigin = .unknown,
        fullKeyboardAccess: Bool = false
    ) {
        self.hasKeyboard = hasKeyboard
        self.origin = origin
        self.fullKeyboardAccess = fullKeyboardAccess
    }

    /// Whether the ring is drawn.
    ///
    /// The mouse-only case is the one this exists to answer: clicking a file in the inspector
    /// pointed the keyboard at the list, drew a two point blue rectangle around the whole pane,
    /// and said nothing the highlighted row was not already saying. Reported as noise, and it is.
    public var showsRing: Bool {
        guard hasKeyboard else { return false }
        if fullKeyboardAccess { return true }
        return origin != .mouse
    }
}
