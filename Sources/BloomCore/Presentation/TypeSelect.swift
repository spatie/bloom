import Foundation

/// Typing the first letters of a row's name to jump to it.
///
/// This is the one list behaviour Mac users notice the absence of first, and the one SwiftUI does
/// not implement: `NSTableView` has had it since before there was a Cocoa, and a SwiftUI `List` on
/// macOS still has nothing. So it is written here, once, and the three lists that had no keyboard
/// at all share it.
///
/// The buffer is the whole of the state: characters accumulate while the reader keeps typing and
/// start again after a pause, so `Pack` `age` reaches Package.swift and `Pack`, a think, `age`
/// starts a fresh search at the a's. Matching is separate from accumulating, and static, because
/// which row a prefix names has nothing to do with when it was typed.
public struct TypeSelect: Sendable, Equatable {
    /// How long a prefix stays alive between keystrokes.
    ///
    /// **A chosen number, not a measured one.** There is no public API for the system's own
    /// type-select timeout and no documented value to copy, so this is picked to sit either side
    /// of the two behaviours it has to separate: long enough that a name typed at a normal speed
    /// arrives as one word, short enough that a reader who stopped, read the row and then typed
    /// again is starting a new search rather than extending an abandoned one.
    public static let window: TimeInterval = 0.75

    /// What the next match is made against. Empty until something is typed.
    public private(set) var buffer = ""

    private var typedAt: Date?

    public init() {}

    /// Adds a character and hands back the prefix to search for.
    ///
    /// Nothing else reads `buffer` to do the search: the return value is the same string, so a
    /// caller cannot accidentally match against the buffer as it was before the keystroke.
    public mutating func accept(_ character: Character, at now: Date) -> String {
        if let typedAt, now.timeIntervalSince(typedAt) > Self.window {
            buffer = ""
        }
        // A clock that went backwards, which happens across a system time change, is treated as a
        // pause rather than as an extension. The alternative is a buffer that can never expire.
        if let typedAt, now < typedAt {
            buffer = ""
        }
        buffer.append(character)
        typedAt = now
        return buffer
    }

    /// Throws the prefix away, for a list that has just lost the keyboard. A reader who clicked
    /// into the composer, typed a sentence and came back is not still spelling a filename.
    public mutating func clear() {
        buffer = ""
        typedAt = nil
    }

    /// Whether a typed character is type-select material at all.
    ///
    /// **The space bar is not, and that is the one deliberate departure from `NSTableView`**,
    /// which does put a space in its buffer. In these lists the space bar is Quick Look, the way
    /// Finder has it, and Finder is the closer precedent for a list of files. A space typed
    /// mid-word therefore ends the word rather than extending it, which costs nothing here: the
    /// rows are filenames and workspace names, and neither has a space in the part anybody types.
    ///
    /// A newline is Return and belongs to `ListKey.activate`. Control characters have no glyph, so
    /// a reader who typed one has not typed anything they can see.
    public static func isTypeSelect(_ character: Character) -> Bool {
        guard !character.isWhitespace, !character.isNewline else { return false }
        return character.isLetter || character.isNumber
            || character.isPunctuation || character.isSymbol
    }

    /// The row a typed prefix names, or nil if nothing matches it.
    ///
    /// Two searches, and which one runs is decided by the length of the prefix, which is how
    /// AppKit tells the two gestures apart without asking the reader to.
    ///
    /// A single character starts **after** the current row and wraps, so pressing `s` again and
    /// again walks every name beginning with s. A longer prefix starts **at** the current row, so
    /// that typing `s`, `r`, `c` refines the row `s` already found rather than skipping past it to
    /// the next thing beginning with src.
    ///
    /// Case and accents are ignored, because somebody typing quickly is not holding shift and a
    /// name with an accent in it is still spelled the way it sounds.
    public static func match(_ prefix: String, in titles: [String], from current: Int?) -> Int? {
        guard !prefix.isEmpty, !titles.isEmpty else { return nil }

        let start = prefix.count == 1
            ? (current.map { $0 + 1 } ?? 0)
            : (current ?? 0)

        let found = (0 ..< titles.count).first { offset in
            titles[(start + offset) % titles.count].range(
                of: prefix,
                options: [.anchored, .caseInsensitive, .diacriticInsensitive]
            ) != nil
        }

        return found.map { (start + $0) % titles.count }
    }
}
