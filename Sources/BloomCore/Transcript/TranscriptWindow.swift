import Foundation

/// A range of a session's rows: what `TranscriptPrime` warms before an arrival, and what the list
/// hands its table, which is the whole session (see `whole`).
///
/// A table builds only the rows on screen and is told every height from a cache, so the whole
/// session costs no more on arrival than a tail, while a tail grown in chunks resized the scroller
/// under the reader by thousands of points at a time.
///
/// **Nothing here decides what a transcript IS.** `TranscriptModel.rows` is the whole session
/// throughout, which is what the unread counts are computed over and what `TurnScan` walks
/// backwards through.
public struct TranscriptWindow: Equatable, Sendable {
    /// The first row drawn, as an index into the session's rows.
    public var start: Int
    /// One past the last row drawn.
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    /// How many rows the window holds once the arrival frame is behind it.
    ///
    /// Deliberately several times `TranscriptTail.length` rather than equal to it. The tail is
    /// sized for one frame and is about three screens; this is what a reader flicking back through
    /// the conversation scrolls through without ever waiting for a growth, and at 7µs a row a pass
    /// four hundred of them is under three milliseconds of layout.
    public static let settled = 400

    /// How many rows above a row that has to be reachable the window starts.
    ///
    /// A search result opens centred in the pane, so the rows above it have to exist or there is
    /// nothing to centre it against, and an unread mark opens at the top of the pane with the same
    /// need for a little history above it to scroll back into.
    public static let margin = 80

    /// The window the frame that arrives at a session draws.
    ///
    /// `mustReach` is the index of a row the reader has asked for by name, which is a search result
    /// or an unread mark: a scroll can only find a row the list is drawing, so the window is moved
    /// to hold it. A row already inside the tail leaves the window exactly where it was, margin and
    /// all: the margin is what a row ARRIVING in a window brings with it, not a claim about every
    /// row.
    public static func opening(rowCount: Int, tailStart: Int, mustReach: Int? = nil) -> Self {
        let tail = Self(start: clamp(tailStart, rowCount: rowCount), end: max(0, rowCount))
        guard let mustReach, mustReach < tail.start else { return tail }
        let start = clamp(mustReach - margin, rowCount: rowCount)
        return Self(start: start, end: clamp(start + margin + settled, rowCount: rowCount))
    }

    /// Where the window settles once the frame that arrived has been drawn.
    ///
    /// Never narrower than it already is, and never moved: a window opened around a search result
    /// must not be pulled back to the live end a hundred milliseconds later, which would take the
    /// row the reader asked for off the list.
    public static func settling(from window: Self, rowCount: Int) -> Self {
        guard window.end >= rowCount else { return window }
        return Self(
            start: min(window.start, clamp(rowCount - settled, rowCount: rowCount)),
            end: max(0, rowCount)
        )
    }

    /// Every row of the session, which is what the list hands its table. See `TranscriptListView`
    /// for why that costs nothing on arrival with a table where it cost 269ms with a lazy stack.
    public static func whole(rowCount: Int) -> Self {
        Self(start: 0, end: max(0, rowCount))
    }

    /// The window's rows in the order a preparation pass should take them: nearest first to the
    /// row the reader lands on.
    ///
    /// A pass that ran from `start` would prepare the reader's own screen last, which is the one
    /// screen it exists to have ready before the table asks. The anchor is the row the list opens
    /// on: the unread mark or the search result when there is one, and the live end otherwise.
    /// An anchor outside the window is pulled to its nearer edge, so a caller never has to check.
    public func indices(outwardFrom anchor: Int) -> [Int] {
        guard count > 0 else { return [] }
        let pinned = min(max(anchor, start), end - 1)
        return (start..<end).sorted { abs($0 - pinned) < abs($1 - pinned) }
    }

    /// How many rows are drawn.
    public var count: Int { max(0, end - start) }

    /// The window clamped to a session, which is what a remembered one has to go through: it was
    /// written down against a row count that may since have grown.
    public func clamped(rowCount: Int) -> Self {
        let end = Self.clamp(self.end, rowCount: rowCount)
        return Self(start: min(Self.clamp(start, rowCount: rowCount), end), end: end)
    }

    /// Keep a window already showing the live end inclusive on the first pass of an append.
    /// Waiting for an onChange drops the temporary bubble before its saved row is in the window.
    public func includingAppendedRows(previousCount: Int, rowCount: Int) -> Self {
        let held = clamped(rowCount: rowCount)
        guard end >= previousCount else { return held }
        return Self(start: held.start, end: max(0, rowCount))
    }

    private static func clamp(_ index: Int, rowCount: Int) -> Int {
        min(max(0, index), max(0, rowCount))
    }

    /// Where a row with this sequence number sits in the session, or the row after it if that
    /// exact one is not there.
    ///
    /// A binary search rather than a scan, because the list asks this on every pass while an
    /// unread mark or a search result is outstanding, and a scan of a four thousand row session
    /// to answer it would be exactly the kind of per-pass walk the rest of this file exists to
    /// remove. Sequence numbers only ever increase down a session, which is what makes the search
    /// valid; nothing here assumes they are contiguous, because a hidden row leaves a gap.
    ///
    /// Nil when every row in the session is older than the one asked about, which is a search
    /// result or an unread mark from a session that has since been read again from the start.
    public static func index<Seqs: RandomAccessCollection>(
        ofSeqAtOrAfter seq: Int, in seqs: Seqs
    ) -> Int? where Seqs.Element == Int, Seqs.Index == Int {
        var low = seqs.startIndex
        var high = seqs.endIndex
        while low < high {
            let middle = low + (high - low) / 2
            if seqs[middle] < seq {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low < seqs.endIndex ? low - seqs.startIndex : nil
    }
}
