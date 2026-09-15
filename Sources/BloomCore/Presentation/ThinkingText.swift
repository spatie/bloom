import Foundation

/// The reasoning a thinking row draws, without the blank lines an agent leaves around it.
///
/// **A fifth of Claude's thinking blocks end in two newlines, and `Text` draws both.** Counted
/// over twenty days of the owner's own sessions: 563 of 2,852 blocks that had any text ended in
/// `\n\n`, and every block that ended in a newline ended in exactly two. An expanded thinking row
/// set that text as it arrived, so a two line sentence came with two more lines of nothing under
/// it, each carrying the prose leading, and the hover fill ran down past all of it. That is the
/// grey box the owner photographed, with two or three lines of empty space at its foot where the
/// padding should have matched the top.
///
/// Trimmed here rather than where the block is parsed, because the stored text is also what is
/// replayed to the API with its signature, and a signed thinking block is not ours to edit. Only
/// what is drawn changes. Grok's thoughts and Codex's summaries pass through the same row, so
/// they are held to the same rule without anyone having to measure theirs.
public enum ThinkingText {
    /// The text with leading and trailing whitespace removed, and the same string, uncopied, when
    /// there was none.
    ///
    /// Both ends are walked from the outside in, so the cost is the whitespace and not the
    /// reasoning: a streaming tail asks this on every delta and a finished block can run to a
    /// hundred kilobytes, where `trimmingCharacters(in:)` bridges and copies the whole string
    /// every time.
    public static func displayed(_ text: String) -> String {
        guard let first = text.firstIndex(where: { !$0.isWhitespace }),
              let last = text.lastIndex(where: { !$0.isWhitespace })
        else { return "" }
        let end = text.index(after: last)
        if first == text.startIndex, end == text.endIndex { return text }
        return String(text[first..<end])
    }
}
