import Foundation

/// What the string in a quick prompt's `symbol` column turns out to be: an SF Symbol name, one
/// emoji, or nothing either view can draw.
///
/// **One column, read for what it holds, rather than a second column and a migration.** Every row
/// written before the picker offered emoji holds an SF Symbol name, and those rows are not going
/// to be rewritten. So the string is classified on the way out: a name like `doc.richtext` is
/// drawn with `Image(systemName:)`, a single emoji is drawn as text, and anything else falls back
/// to `QuickPrompt.defaultSymbol` rather than leaving a hole in the row. `Image(systemName:)` with
/// a name macOS does not know renders an empty box, which is the failure this fallback exists to
/// stop, and it is why the symbol half is a list membership test and not a guess.
///
/// The emoji half is deliberately **not** a list membership test. See `isEmoji` below.
public enum QuickPromptMark: Sendable, Hashable {
    /// An SF Symbol name the picker offers. See `QuickPrompt.symbols`.
    case symbol(String)
    /// One emoji character, whichever one it is.
    case emoji(String)

    /// Reads a stored value for what it is.
    ///
    /// Order matters here and only in one direction: an SF Symbol name is ASCII with full stops in
    /// it and can never be a single emoji character, so the two tests cannot both pass.
    public init(stored: String) {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 1, let character = trimmed.first, Self.isEmoji(character) {
            self = .emoji(String(character))
        } else if QuickPrompt.knownSymbols.contains(trimmed) {
            self = .symbol(trimmed)
        } else {
            self = .fallback
        }
    }

    /// What a row with nothing usable in its column is drawn as.
    public static let fallback = QuickPromptMark.symbol(QuickPrompt.defaultSymbol)

    /// What goes back into the column.
    public var stored: String {
        switch self {
        case .symbol(let name): name
        case .emoji(let emoji): emoji
        }
    }

    /// Whether this one is a full colour glyph rather than a tinted one, which is the whole of what
    /// a view needs to know to draw it. See `QuickPromptMarkView`.
    public var isEmoji: Bool {
        if case .emoji = self { return true }
        return false
    }

    /// Whether a character is an emoji, asked of the character's own properties rather than of a
    /// list.
    ///
    /// **The list is the bug this avoids.** While the picker's own set was the only thing that made
    /// an emoji an emoji, a mark pasted in by hand, or one a later build offered and an earlier
    /// build then opened, drew as the fallback even though the string in the column was perfectly
    /// good. Unicode already knows the answer, so it is asked.
    ///
    /// Two clauses, because `isEmoji` alone is true of things nobody would call one. A digit, `#`
    /// and `*` all carry it, because each can be the base of a keycap sequence, and so do `(c)`,
    /// `(r)` and the trade mark sign. What separates them is presentation: an emoji is either drawn
    /// as one by default (`isEmojiPresentation`), or made into one by something following it, which
    /// is the variation selector in `\u{2699}\u{FE0F}`, the keycap in `1\u{FE0F}\u{20E3}`, a skin
    /// tone, or a zero width joiner. A lone `1` is neither, and stays a character.
    private static func isEmoji(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        guard let first = scalars.first, first.properties.isEmoji else { return false }
        return first.properties.isEmojiPresentation || scalars.count > 1
    }
}
