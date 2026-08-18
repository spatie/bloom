import Foundation

/// The one or two characters that stand for a project where there is no room for its name.
///
/// A colour on its own cannot identify a project. `Accent.all` holds ten hexes and then starts
/// reusing them, and the colour is editable in Settings, so two projects can legitimately be the
/// same green. Letters taken from the name are the only mark that is always available, always as
/// distinct as the names themselves, and needs nothing from the network or from GitHub.
///
/// Pure and in the core so the rule is pinned by tests rather than judged from a screenshot. The
/// drawing lives in `RepoIcon`; nothing here knows what a colour is.
public enum RepoMonogram {
    /// `there-there` gives `TT`, `bloom` gives `BL`, `my-app-2` gives `MA`.
    ///
    /// Returns an empty string when the name carries nothing to take, which is the tile's cue to
    /// draw its colour and no letters rather than to invent a placeholder character.
    public static func initials(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "" }

        // An emoji is already a mark, and reducing "🌸 garden" to "G" throws away the one
        // character the user chose to be recognised by. Only a LEADING emoji counts: in
        // "bloom 🌸" the word is still what names the project.
        if isPictograph(first) { return String(first) }

        let words = words(in: trimmed)
        // A number is not an initial: `my-app-2` is the app, not the 2.
        let named = words.filter { $0[0].isLetter }

        if named.count >= 2 {
            return String([upper(named[0][0]), upper(named[1][0])])
        }
        if let only = named.first {
            return String(only.prefix(2).map(upper))
        }
        // Nothing but digits, as in a project called `2048`. Two of them still identify it.
        if let digits = words.first {
            return String(digits.prefix(2).map(upper))
        }
        return ""
    }

    /// The name split into runs of letters and digits, with camel humps counted as breaks so
    /// `MyApp` gives `MA` rather than `MY`.
    ///
    /// A run of capitals is deliberately not broken up: `HTTPServer` gives `HT`, which is at
    /// least stable, where breaking on every capital would give `HS` and read as a different
    /// project than the folder it came from.
    private static func words(in name: String) -> [[Character]] {
        var words: [[Character]] = []
        var current: [Character] = []

        func flush() {
            guard !current.isEmpty else { return }
            words.append(current)
            current = []
        }

        for character in name {
            guard character.isLetter || character.isNumber else {
                // Every separator a repository folder is ever called: `-`, `_`, `.`, `/`, a space.
                flush()
                continue
            }
            if character.isUppercase, let previous = current.last, !previous.isUppercase {
                flush()
            }
            current.append(character)
        }
        flush()
        return words
    }

    /// Uppercased one character at a time, because `"ß".uppercased()` is `"SS"` and a monogram
    /// that silently becomes three characters wide overflows the tile it is drawn in.
    private static func upper(_ character: Character) -> Character {
        character.uppercased().first ?? character
    }

    /// Whether the character is a picture rather than a letter.
    ///
    /// `isEmojiPresentation` alone misses the ones that are drawn as emoji only because a
    /// variation selector follows them (`❤️`, `1️⃣`), and `isEmoji` alone is true for bare `#`,
    /// `*` and every digit, which are text. Together they are right for both.
    private static func isPictograph(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        if scalar.properties.isEmojiPresentation { return true }
        return scalar.properties.isEmoji && character.unicodeScalars.count > 1
    }
}
