import Foundation

/// How much of one diff line is drawn, which for nearly every line is all of it.
///
/// **This exists because one line of a minified bundle froze the whole app.** Feedback #25 was a
/// worktree with thirty uncommitted files that "crashed every five minutes" while the diff was
/// being built. Recreated with a 3.5 MB single line `app.min.js` among them, Bloom beachballed at
/// 100% CPU for minutes and did not come back: both stack samples were entirely inside
/// `-[NSTextView setFrameSize:]`, with TextKit typesetting the one paragraph on the main thread.
/// The 5,000 line gate did not stop it because it counts lines, and this file was one.
///
/// The cost is not linear, which is why nothing smaller than a cap will do. Measured headless with
/// the diff's own font and wrapping, one line with a colour run every six characters (which is
/// what highlighting makes of minified code) took 0.35 s at 303 KB and 1.22 s at 614 KB. Plain
/// text with no runs wrapped 5 MB in 0.69 s, so it is the runs, and a highlighted line cannot be
/// drawn without them.
///
/// Only what is DRAWN is shortened. `DiffLine.text` keeps the whole line, because editing a line
/// in place and reverting it both write that text back to disk, and a line cut here and saved
/// there would be a file quietly truncated. Every view that draws, highlights or measures a diff
/// line goes through `text(_:)`, so the three agree on what the line is.
public enum DiffLineDisplay {
    /// The most characters of one line that are drawn.
    ///
    /// Two thousand is wider than any line a person wrote to be read, costs nothing measurable to
    /// lay out, and is deliberately not below `DiffParser.intraLineLimit`: a shortened line is
    /// then always one the word diff already declined, so it has no emphasis ranges pointing past
    /// the cut.
    public static let limit = 2_000

    /// The line as drawn: the whole of it, or its first `limit` characters and a note of how much
    /// was left out.
    ///
    /// Cheap on a line of any length. The byte count is constant time, and a line within the
    /// limit in bytes is within it in characters, so almost every call returns at once; the rest
    /// walk `limit` characters and no further.
    public static func text(_ line: String) -> String {
        guard line.utf8.count > limit else { return line }
        let shown = line.prefix(limit)
        // Over the limit in bytes and not in characters: a line of CJK or emoji, drawn whole.
        guard shown.endIndex < line.endIndex else { return line }
        return String(shown) + omission(bytes: line.utf8.count - shown.utf8.count)
    }

    /// Said in bytes rather than characters, because counting the characters of a 3.5 MB line is
    /// the walk this type exists to avoid, and a size is what the reader wants to know anyway.
    static func omission(bytes: Int) -> String {
        " … " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            + " more on this line, not shown"
    }
}
