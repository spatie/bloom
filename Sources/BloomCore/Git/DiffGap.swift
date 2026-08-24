import Foundation

/// The unchanged region git never printed, between one hunk and the next.
///
/// A unified diff prints a few lines of context either side of a change and nothing in between,
/// so the reader who wants to see what a change sits in presses an expander and the gap gives up
/// a few lines at a time. Which lines those are is arithmetic on two hunks and a count, and it
/// was written out **twice, verbatim, 120 lines apart** in `DiffView`: once to build the rows
/// that get drawn, and once to tell `ReviewPlacements` which line numbers are on screen.
///
/// They were identical, and that is exactly the problem. A pending review comment anchors to a
/// line by number, and the two halves have to agree about which numbers are printed: if they ever
/// drift, a comment anchors to a line that is not on screen and the band is drawn against
/// nothing. Two copies of arithmetic that must agree is one copy too many, and it was in a view,
/// so nothing could check either of them.
public enum DiffGap {
    /// How far the gap before `hunks[index]` runs, or nothing when the hunks touch.
    ///
    /// Measured on the new side, because that is the side the file on disk is, and revealing a
    /// gap reads the worktree copy. The first hunk's gap runs back to line 1, which is the head of
    /// the file rather than a previous hunk.
    ///
    /// Nil rather than zero for "no gap", so a caller cannot accidentally treat an empty range as
    /// a range of one line.
    public static func between(hunks: [DiffHunk], at index: Int) -> Range<Int>? {
        guard hunks.indices.contains(index) else { return nil }
        let hunk = hunks[index]
        let previousEnd = index == 0
            ? 1
            : hunks[index - 1].newStart + hunks[index - 1].newCount
        guard hunk.newStart > previousEnd else { return nil }
        return previousEnd..<hunk.newStart
    }

    /// The new-side line numbers a gap is currently showing, given how many the reader has asked
    /// for.
    ///
    /// Revealed **upward from the hunk**, which is the way a reader walks back out of a change:
    /// the lines nearest what changed come first. Clamped to the gap, so a reader who kept
    /// pressing past the top of it does not run into the hunk above.
    public static func revealed(_ requested: Int, in gap: Range<Int>) -> Range<Int> {
        let count = min(max(requested, 0), gap.count)
        return (gap.upperBound - count)..<gap.upperBound
    }

    /// How many lines of the gap are still hidden, which is what the expander offers to show.
    public static func hidden(_ requested: Int, in gap: Range<Int>) -> Int {
        gap.count - revealed(requested, in: gap).count
    }
}
