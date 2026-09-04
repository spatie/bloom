import SwiftUI

/// Text with the characters a fuzzy match hit carried at full weight and colour, and the rest
/// stepped back.
///
/// **Runs rather than characters, so a hit reads as a word.** Typing `revi` lights the `revi`
/// inside `security-review` rather than the stray `r` of `secu(r)ity`, because the matcher reports
/// the run it scored rather than the first letters it could reach.
///
/// **Built by interpolating one styled `Text` per run**, which is what macOS 26 leaves once `+` on
/// two `Text`s is deprecated. An `AttributedString` would be the shorter spelling and is the wrong
/// one here: its SwiftUI scope carries `font` and no `fontWeight`, so bolding a run would mean
/// naming a whole font and the row would stop inheriting the list's own.
///
/// It was `SlashCommandRow`'s, privately, and it is here because the search panel draws a workspace
/// name and a command title exactly the same way. Two copies of this would be two answers to
/// "which characters matched", drawn an inch apart.
enum MatchedRuns {
    static func text(_ string: String, highlights: [Int], loud: Color, quiet: Color) -> Text {
        var runs = LocalizedStringKey.StringInterpolation(literalCapacity: 0, interpolationCount: 0)
        append(string, highlights: highlights, loud: loud, quiet: quiet, to: &runs)
        return Text(LocalizedStringKey(stringInterpolation: runs))
    }

    /// The same, appended to an interpolation a caller has already started, which is what lets the
    /// slash menu draw its `/` in the quiet colour before the name.
    static func append(
        _ string: String,
        highlights: [Int],
        loud: Color,
        quiet: Color,
        to runs: inout LocalizedStringKey.StringInterpolation
    ) {
        guard !highlights.isEmpty else {
            runs.appendInterpolation(Text(string).foregroundStyle(loud))
            return
        }

        let characters = Array(string)
        let hits = Set(highlights)
        var index = 0
        while index < characters.count {
            let isHit = hits.contains(index)
            var end = index
            while end < characters.count, hits.contains(end) == isHit { end += 1 }
            let run = Text(String(characters[index..<end]))
            runs.appendInterpolation(
                isHit ? run.fontWeight(.bold).foregroundStyle(loud) : run.foregroundStyle(quiet)
            )
            index = end
        }
    }
}
