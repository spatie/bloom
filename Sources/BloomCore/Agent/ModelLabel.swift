import Foundation

/// Turning an identifier nobody chose into something a person can read.
///
/// Model ids and permission modes reach Bloom verbatim from a settings file or from a session's
/// own init line, so the ones Bloom ships a label for are a list that is always behind. Everything
/// else is tidied rather than silently rewritten or dropped.
///
/// In the core rather than beside the chip that draws it, because it is a pure function with a
/// branch in it and the test target cannot reach `Sources/Bloom`. It got there by being wrong:
/// `claude-opus-4-6` rendered as "Opus 4 6", a version number with a space in the middle of it,
/// on every session-start row of every workspace, and nothing could have caught it.
public enum ModelLabel {
    /// `acceptEdits` and `claude-opus-5[1m]` both become something a person can read, without
    /// capitalising the parts that are not words.
    ///
    /// The vendor prefix goes: inside Bloom every model is a Claude model, so the word carries no
    /// information and only costs room in a chip.
    public static func readable(_ id: String) -> String {
        let parts = id.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." })

        guard !parts.isEmpty else { return id }

        // Unless the vendor name is all there is, in which case dropping it leaves nothing to read.
        let named = parts.drop { $0.lowercased() == "claude" }
        let kept = named.isEmpty ? parts[...] : named

        return join(kept.map(tidy))
    }

    private static func tidy(_ part: Substring) -> String {
        let bracketed = part.replacing("[", with: " (").replacing("]", with: ")")

        guard let first = bracketed.first, first.isLetter else { return String(bracketed) }

        return first.uppercased() + bracketed.dropFirst()
    }

    /// Spaces between words, a full stop between two numbers.
    ///
    /// The separator a version uses is the one thing the id has already thrown away: `opus-4-6`
    /// and `opus-4.6` arrive identical, because both separators split. Two numeric parts in a row
    /// are a version rather than two words, so they are rejoined the way a version is written.
    /// Without this the chip read "Opus 4 6", which is not a version anybody would recognise.
    private static func join(_ parts: [String]) -> String {
        var result = ""

        for (index, part) in parts.enumerated() {
            if index > 0 {
                result += isNumeric(part) && isNumeric(parts[index - 1]) ? "." : " "
            }
            result += part
        }

        return result
    }

    /// A part made only of digits. `1m` is not one: it is a context window, and "5.1m" would read
    /// as a version this model does not have.
    private static func isNumeric(_ part: String) -> Bool {
        !part.isEmpty && part.allSatisfy(\.isNumber)
    }
}
