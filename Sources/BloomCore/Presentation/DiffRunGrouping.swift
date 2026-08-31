import Foundation

/// Which consecutive rows of a rendered diff may be drawn as one run of selectable text.
///
/// **This exists because a diff drawn as one `Text` per line cannot be selected across lines.**
/// Sibling text views are separate selection scopes on this platform, so dragging down a hunk
/// selected the single line the drag began on, and there was no other way to get two lines out of
/// a diff: the app has no copy command for one. `CodeBlockView` reached the same conclusion about
/// a markdown fence and wrote the rule down; this is that rule applied to a diff, where the run
/// has to stop at everything a fence does not have.
///
/// It is index arithmetic and nothing else, so that the app target hands it a count and a
/// predicate rather than its own row type. A decision taken inside a view is a decision nothing
/// can test, and this one has four ways to be wrong at the edges.
public enum DiffRunGrouping {
    /// One item in the rendered list: either a row that stands alone, or a stretch of line rows
    /// drawn together.
    public enum Chunk: Equatable, Sendable {
        /// The row at this index, drawn the way it always was.
        case single(Int)
        /// Two or more line rows, drawn as one block of text so a selection can cross them.
        case run(Range<Int>)
    }

    /// The longest run drawn as one block.
    ///
    /// **A cap rather than "the whole hunk", because a run is one item in a lazy stack and a lazy
    /// stack can only skip what it has not realised.** Per line the stack realises a screenful;
    /// per hunk a wholly new file is a single item, and the diff is gated at 5,000 changed lines,
    /// so the worst case was one item holding all of them. Measured on this machine at the
    /// callout text size: 5,000 lines cost 54ms to build the string and 42ms to lay out, in one
    /// frame, against 8ms and under 4ms for 400. Four hundred lines is about fifteen screens, far
    /// past what anybody drags through in one gesture, so the cap costs a selection nothing it
    /// would have been asked for and keeps the stack's items the size it can skip.
    public static let runLimit = 400

    /// Group a rendered row list into blocks.
    ///
    /// `isLine` answers whether the row at an index is a plain line of code, which is the only
    /// kind that may join a run. Everything else (a hunk heading, either expander, a review
    /// comment band, the open comment editor) breaks the run, because each of those draws a view
    /// between two lines and text cannot flow through one.
    ///
    /// A stretch of one is reported as `.single`, never as a run of one. There is nothing to
    /// select across, and it keeps the per line path in service for exactly the rows that need
    /// it: in the review pane a comment band under every commented line leaves its neighbours
    /// alone, and those rows go on being drawn by the view that has always drawn them.
    public static func chunks(
        count: Int,
        isLine: (Int) -> Bool,
        limit: Int = runLimit
    ) -> [Chunk] {
        // A limit under two would make every run a `.single` and quietly turn the fix off. It is
        // a caller's mistake rather than a state to support, and floored rather than trapped
        // because a diff that draws is worth more than a precondition that is right.
        let limit = max(2, limit)
        var chunks: [Chunk] = []
        var index = 0

        while index < count {
            guard isLine(index) else {
                chunks.append(.single(index))
                index += 1
                continue
            }

            var end = index
            while end < count, isLine(end), end - index < limit { end += 1 }

            if end - index == 1 {
                chunks.append(.single(index))
            } else {
                chunks.append(.run(index..<end))
            }
            index = end
        }

        return chunks
    }
}
