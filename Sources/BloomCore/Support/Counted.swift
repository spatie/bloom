import Foundation

/// A number and the noun it counts, in one string: "1 line", "3 lines", "1,024 tokens".
///
/// Here because the two halves of it are both decisions and both kept being got wrong at the call
/// site. A count is written with `.formatted()` so the thousands separator is the reader's rather
/// than none, and the noun agrees with the number, so "Expand 1 lines" and "1 tokens" cannot be
/// reached. Neither is visible in a view's source until the day the count happens to be one.
///
/// `ArchiveDeletion.count` was this function under another name, on a type about deleting an
/// archive, and its own doc already recorded that three views wrote it again rather than reach for
/// it and that two of the three dropped `.formatted()` on the way. It now delegates here, so the
/// archive's wording and a diff expander's cannot drift.
public enum Counted {
    /// - Parameter plural: for the nouns an `s` does not pluralise. "match" is the one that forced
    ///   it: Home's transcript heading counts matches, and "1 matchs" is the sort of thing a
    ///   reader stops on.
    public static func of(_ value: Int, _ noun: String, plural: String? = nil) -> String {
        "\(value.formatted()) \(word(value, noun, plural: plural))"
    }

    /// The noun alone, agreeing with a count that is written somewhere else in the sentence.
    public static func word(_ value: Int, _ noun: String, plural: String? = nil) -> String {
        value == 1 ? noun : (plural ?? noun + "s")
    }
}
