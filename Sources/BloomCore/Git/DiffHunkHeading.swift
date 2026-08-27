import Foundation

/// The `@@` band above a hunk, and whether it is worth drawing at all.
///
/// **A grey strip reading `{} public function __construct(` sat between line 48 and line 49 with
/// the numbering running straight through it.** The band is orientation: it tells a reader where
/// they have landed after code the diff did not print. Between two lines that follow each other
/// it names a scope the reader is already inside and marks a landing that never happened, and the
/// row is a row of noise in the middle of a file somebody is reading.
///
/// So it is drawn exactly when the eye has jumped: when the lines printed above the hunk are not
/// the lines that precede it in the file. That is `DiffGap` again, asked about what is **still**
/// hidden rather than about the patch, and the difference matters. A gap is revealed upward from
/// the hunk, so the moment one line of it is up, the line above the band is contiguous with the
/// hunk. That is where the band in the report came from: git does not emit touching hunks at
/// three lines of context (measured, and the arithmetic in `xdl_get_hunk` says so: changes closer
/// than twice the context are merged into one hunk, which leaves at least one unprinted line
/// between any two it does split), so contiguity in the pane is always the reader's own expander.
///
/// **A changed scope is deliberately not a case of its own.** It cannot arise alone: contiguity
/// only ever comes from a fully revealed gap, and revealing the gap prints the very source line
/// the band would have quoted, so the band would restate a line already on the screen.
public enum DiffHunkHeading {
    /// What the band above `hunks[index]` should read, or nothing when it would say nothing.
    ///
    /// `revealed` is how many lines of the gap above that hunk the reader has asked the expander
    /// for. Both layouts go through this one call rather than deciding for themselves, because a
    /// unified pane and a split pane disagreeing about which bands exist is a difference nobody
    /// could read as anything but a bug.
    public static func text(for hunks: [DiffHunk], at index: Int, revealed: Int) -> String? {
        guard hunks.indices.contains(index) else { return nil }
        guard let gap = DiffGap.between(hunks: hunks, at: index) else { return nil }
        guard DiffGap.hidden(revealed, in: gap) > 0 else { return nil }
        return text(of: hunks[index])
    }

    /// The enclosing scope git named, falling back to the hunk's own coordinates.
    ///
    /// Git leaves the name off whenever its funcname patterns find nothing above the hunk, which
    /// is every hunk at the head of a file and every hunk of a file it has no patterns for. The
    /// coordinates are kept rather than the band being dropped, because they are the only mark of
    /// the jump left when the worktree copy could not be read: without it `DiffView.appendGap`
    /// draws neither the expander nor a revealed line, and the rows would run from one part of
    /// the file into another with nothing in between.
    static func text(of hunk: DiffHunk) -> String {
        let trimmed = hunk.header.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@"
    }
}
