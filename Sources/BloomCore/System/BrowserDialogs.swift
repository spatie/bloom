import Foundation

/// The three questions a page can ask the person reading it: `alert`, `confirm` and `prompt`.
///
/// A browser pane answered none of them, because there was no `WKUIDelegate`, and WebKit's answer
/// to a missing one is to return the default and say nothing. So `confirm` was always false,
/// `prompt` was always null, and a page that waited for the reader to agree to something waited
/// for ever. This is what decides how each one is put up.
///
/// ## Two things a page controls, and what is done about each
///
/// **The words.** Every character of the message is written by the page, and the panel it lands on
/// is chrome the reader trusts. A page that writes "Bloom needs your GitHub token" into an alert
/// is doing the oldest trick there is, and the answer every browser reached is the same: Bloom's
/// own line at the top saying which site is speaking, and the page's words underneath it as an
/// informative paragraph. `BrowserPageOrigin` is what names the site, and it is host and port
/// rather than anything a page can write.
///
/// The words are also cut down. A page can pass a megabyte to `alert`, and `NSAlert` has no
/// scroller: it lays the whole string out and grows, so an alert taller than the display has an OK
/// button nobody can reach, and that is a window nobody can get out of. Control characters go for
/// the same reason, because a run of them draws as nothing at all and a dialog that appears empty
/// is a dialog that reads as broken.
///
/// **How many.** `while (true) alert()` is a loop that puts up a window-modal sheet, waits for it
/// to be answered, and puts up the next one, which locks the reader out of the whole window for as
/// long as the page cares to keep going. Every browser answers this the same way too, with a tick
/// box on the second dialog offering to stop the page raising any more, so this counts them: from
/// the second dialog since the page last committed a document, the box is offered, and ticking it
/// makes every later question answer itself with the safe answer until the page navigates.
///
/// The reset is a navigation and not a timer, because "this page" is what the reader was told they
/// were silencing, and a page they have since left is a different promise.
public struct BrowserDialogs: Sendable, Equatable {
    /// Which of the three was asked. The safe answer differs, which is why the caller switches on
    /// it rather than being handed one value.
    public enum Kind: Sendable, Equatable {
        case alert
        case confirm
        case prompt
    }

    /// What to put on screen, once the page's words have been made safe to draw.
    public struct Presentation: Sendable, Equatable {
        /// Bloom's own line, naming who is speaking.
        public var title: String
        /// The page's words, trimmed of anything that cannot be drawn and cut to a length a panel
        /// can hold.
        public var message: String
        /// What a `prompt` starts with in its field, cut the same way and to one line.
        public var defaultText: String
        /// Whether to offer the reader a way to stop this page asking anything else.
        public var offersSuppression: Bool

        public init(
            title: String,
            message: String,
            defaultText: String = "",
            offersSuppression: Bool = false
        ) {
            self.title = title
            self.message = message
            self.defaultText = defaultText
            self.offersSuppression = offersSuppression
        }
    }

    public enum Decision: Sendable, Equatable {
        case show(Presentation)
        /// The reader has already said this page may not ask anything else. Answer it with the
        /// safe answer and put nothing on screen.
        case suppress
    }

    /// How many dialogs this document may put up before the tick box is offered. The second one
    /// carries it, which is where Safari and Chrome both put it.
    public static let suppressionOffered = 2
    /// The most of a page's message that is drawn. Long enough for any sentence anybody means to
    /// write, short enough that the panel keeps its buttons on the display.
    public static let messageLimit = 900
    /// And the most lines of it, for the same reason: 900 characters of newlines is 900 lines.
    public static let lineLimit = 12

    /// How many this document has put up since it committed.
    private var shown = 0
    /// Whether the reader has told this document to stop.
    private var isSilenced = false

    public init() {}

    /// Asks how a dialog should be put up, and counts it.
    ///
    /// `name` is what `BrowserPageOrigin.name` made of the frame's origin, or nothing for a
    /// document with no host, which is one loaded from a string or a file.
    public mutating func request(
        _ kind: Kind,
        message: String,
        defaultText: String = "",
        from name: String? = nil
    ) -> Decision {
        guard !isSilenced else { return .suppress }
        shown += 1
        return .show(
            Presentation(
                title: Self.title(from: name),
                message: Self.readable(message),
                defaultText: kind == .prompt ? Self.oneLine(defaultText) : "",
                offersSuppression: shown >= Self.suppressionOffered
            )
        )
    }

    /// The reader ticked the box. Everything this document asks from here answers itself.
    public mutating func silence() {
        isSilenced = true
    }

    /// A document committed in this pane, which is the one thing that undoes a silencing and
    /// starts the count again. A `pushState` is not one of these, and should not be: it is the
    /// same document, and the reader silenced a page rather than an address.
    public mutating func pageCommitted() {
        shown = 0
        isSilenced = false
    }

    /// Whether the reader has silenced the page currently loaded.
    public var isSilent: Bool { isSilenced }

    // MARK: - Making a page's words drawable

    /// Bloom's own line above the page's words.
    ///
    /// "says" rather than a colon or an exclamation, because it is the sentence every browser on
    /// every platform puts there and the reader has read it a thousand times.
    static func title(from name: String?) -> String {
        guard let name else { return "This page says" }
        return "\(name) says"
    }

    /// The page's message, made into something a panel can hold.
    ///
    /// Control characters out, because a run of them draws as nothing and an empty-looking dialog
    /// reads as a broken app rather than as a page misbehaving. Tabs and newlines stay, because a
    /// real message is laid out with them. Then the lines are capped and the whole thing is capped,
    /// and either cut is said with an ellipsis rather than done silently.
    static func readable(_ message: String) -> String {
        var text = String(message.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar)
        })

        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > lineLimit {
            lines = Array(lines.prefix(lineLimit))
            text = lines.joined(separator: "\n") + "\n..."
        } else {
            text = lines.joined(separator: "\n")
        }

        if text.count > messageLimit {
            text = String(text.prefix(messageLimit)) + "..."
        }
        return text
    }

    /// A `prompt`'s starting text, which goes into a field rather than a paragraph, so it is one
    /// line and a short one.
    static func oneLine(_ text: String) -> String {
        let flattened = readable(text)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        return String(flattened.prefix(messageLimit))
    }
}
