import Foundation

/// What Find in Page is doing in a browser pane, and what its bar says.
///
/// `Cmd F` is the most reflexive keystroke on this platform and the browser pane answered it with
/// nothing at all. The review that asked for this puts it first: a Mac app finds the thing in
/// front of you, in Mail, Safari, Terminal, Preview, Notes and Xcode without exception.
///
/// ## What WebKit will and will not tell us
///
/// `WKWebView.find(_:configuration:)` answers with a `WKFindResult`, and that type has exactly one
/// property on it: `matchFound`. There is no match count and no index, so the bar cannot say
/// "3 of 17" however much it would like to, and pretending otherwise would mean running a script
/// of our own over the page to count, which is the thing `BrowserPaneCommand` argues at length
/// that this pane does not do. So the bar says nothing when there is a match and "Not found" when
/// there is not, which is the honest half of Safari's banner.
///
/// ## Smart case, and why it is not Safari's rule
///
/// Safari's find is always case insensitive. This is not, and the reason is what a browser pane in
/// this window is for: it is pointed at a dev server, and the thing being looked for is as often
/// an identifier as a word. A reader who types `userId` means `userId` and not `userid`, and a
/// reader who types `submit` means any of them. Typing a capital is the only signal available and
/// it is the one Xcode and every editor in this repository's world already reads.
public struct BrowserFind: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        /// Nothing has been looked for yet, or the field has been emptied.
        case idle
        case found
        case notFound
    }

    /// Whether the bar is on screen. The query survives it being closed, so reopening find and
    /// pressing Return steps the same search rather than starting from an empty field.
    public var isShowing = false
    public var query = ""
    public var outcome: Outcome = .idle

    public init() {}

    /// Whether there is anything to step through. An empty field is not a search, and the arrows
    /// beside it should say so rather than doing nothing when pressed.
    public var canStep: Bool { !query.isEmpty }

    /// What the bar says to the right of the field.
    ///
    /// Empty for a match, because WebKit gives no count and "Found" under a highlighted word is a
    /// line that says less than the highlight does.
    public var status: String {
        switch outcome {
        case .idle, .found: ""
        case .notFound: "Not found"
        }
    }

    /// Whether the search should respect capitals, which is decided by whether the reader typed
    /// any. See the note above about why this is not Safari's rule.
    public var isCaseSensitive: Bool {
        query.contains { $0.isUppercase }
    }

    /// How many times the bar has been asked for.
    ///
    /// The bar takes the keyboard when this moves rather than when `isShowing` does, because a
    /// second `Cmd F` while the bar is already up has to put the caret back in the field: that is
    /// what the key does in every other application, and watching `isShowing` alone would make it
    /// do nothing at all.
    public private(set) var opens = 0

    /// Opens the bar. The query is kept, so `Cmd F` twice in a row does not lose what was typed.
    public mutating func show() {
        isShowing = true
        opens += 1
    }

    public mutating func hide() {
        isShowing = false
        outcome = .idle
    }

    /// The field changed. A field emptied is not a search that failed, so the "Not found" goes
    /// with the text rather than sitting under an empty box.
    public mutating func type(_ text: String) {
        query = text
        if text.isEmpty { outcome = .idle }
    }

    public mutating func settle(matched: Bool) {
        guard canStep else { return outcome = .idle }
        outcome = matched ? .found : .notFound
    }
}

/// The four things the keyboard asks of Find in Page.
///
/// Its own type in the core so that both routes into it agree: the Edit menu's Find items, which
/// arrive as `performFindPanelAction` down the responder chain, and the key equivalents a browser
/// pane claims for itself while its page holds the keyboard. Two mappings written separately are
/// two mappings that eventually disagree about `Shift Cmd G`.
public enum BrowserFindCommand: Sendable, Equatable {
    case show
    case next
    case previous
    case hide

    /// What a key press means to a browser page, or nothing when it means nothing.
    ///
    /// Only the presses this pane should take. Everything else must fall through, because a
    /// browser pane claiming a key while it merely exists is how `Cmd W` came to close a chat
    /// session in a different pane, and because the menu bar is entitled to the rest.
    ///
    /// `characters` is the unmodified string off the event, lowercased by the caller or not: both
    /// spellings are read here, since `Shift Cmd G` delivers "G" and `Cmd G` delivers "g".
    public static func forKey(
        _ characters: String,
        hasCommand: Bool,
        hasShift: Bool
    ) -> BrowserFindCommand? {
        guard hasCommand else { return nil }
        switch characters.lowercased() {
        case "f": return hasShift ? nil : .show
        case "g": return hasShift ? .previous : .next
        default: return nil
        }
    }
}
