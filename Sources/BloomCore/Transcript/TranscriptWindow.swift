import Foundation

/// How much of a session the list draws, and when that moves.
///
/// **Read `whole` first.** Everything below it was written for a `LazyVStack`, which the transcript
/// no longer uses, and the argument the rest of this header makes is that stack's. A session small
/// enough is drawn in one piece now, and none of the stepped growth below happens at all.
///
/// **A lazy stack is lazy about realising a row and is not lazy about knowing one.** Placing its
/// subviews walks every child it has been handed, realised or not, so the cost of a layout pass
/// follows the length of the conversation rather than the height of the pane. Measured on a
/// release build at 1440 by 900, resizing a window over a 1,582 row chat: 11.1ms per pass of the
/// centre column with the whole session in the stack, 4.6ms with eighty rows in it and the same
/// session on screen, against 1.6ms for a pane holding an empty one. A resize is two to three
/// passes a frame, so that difference is the difference between six frames a second and something
/// a hand can follow.
///
/// `TranscriptTail` already answered half of this: the frame that ARRIVES at a session draws its
/// last eighty rows, because resolving a position at the end of a stack realises everything above
/// it. What it did next was hand the stack the whole session a hundred milliseconds later, so the
/// saving lasted exactly one frame and every resize, scroll and streamed token for the rest of the
/// visit paid for four thousand children. This is that second half.
///
/// # Why it has two ends
///
/// The first version had one, and a window that started somewhere and ran to the end of the
/// session. It was measured drawing all 1,582 rows of the fixture anyway, and the reason is the
/// case Bloom is FOR: an agent works while you are somewhere else, so the first unread row is
/// often near the beginning of a long conversation. The list opens on that row, a scroll can only
/// find a row the list is drawing, and a window that starts there and runs to the end is the whole
/// session with extra steps.
///
/// So it is a range. A session opened on an old row draws that row's neighbourhood, and the rows
/// below it arrive as the reader scrolls down towards them, which costs nothing to arrange:
/// content added BELOW the viewport moves nothing, where content added above it needs the bottom
/// anchor to hold the view still.
///
/// **Nothing here decides what a transcript IS.** `TranscriptModel.rows` is the whole session
/// throughout, which is what the unread counts are computed over and what `TurnScan` walks
/// backwards through. This is a drawing decision and only the list takes it.
public struct TranscriptWindow: Equatable, Sendable {
    /// The first row drawn, as an index into the session's rows.
    public var start: Int
    /// One past the last row drawn. `rowCount` whenever the live end is in the window, which is
    /// every state except a session opened on an old row and not yet scrolled down from.
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

    /// How many rows a growth adds. The same figure as `settled`, because the reason for the size
    /// is the same: enough that reaching the next growth takes a deliberate scroll rather than a
    /// flick, and small enough that adding it is a layout of a few milliseconds.
    public static let chunk = 400

    /// **The most rows a session can have and still be drawn in one piece.**
    ///
    /// Everything above this line was written for a `LazyVStack`, and the numbers in this file's
    /// header are that stack's: a lazy stack places every child it holds on every pass, realised
    /// or not, so the window existed because the cost of a layout followed the length of the
    /// conversation. The transcript is an `NSTableView` now. A table knows a row count, keeps its
    /// own row geometry and builds a view only for what is in the visible rect, so holding four
    /// thousand rows costs it nothing per pass.
    ///
    /// What a window costs INSTEAD, under a table, is the arriving. Growing it by four hundred
    /// rows rebuilds every entry the list holds, diffs the whole list, rebuilds its index and
    /// inserts four hundred rows into the table, all on a frame the reader is scrolling through.
    /// Reported, unprompted and twice: "lines get added to the view then they stutter when
    /// scrolling", and "if i scroll to bottom and then up again, those lines that were added
    /// previously don't stutter anymore". A session drawn whole arrives once, when it opens, and
    /// never again.
    ///
    /// **The number is a bound rather than a measurement, and it is honest about which.** What
    /// scales with the window under a table is the pass that assembles the entries: a content key
    /// hashed from a dozen fields, two closures and a payload sniff, per row, on every pass this
    /// view runs. Nobody has timed one entry, so the cost of a four thousand row pass is not
    /// known. It is set above every session in the owner's database, which has seventeen of them
    /// and tops out at 2,981 rows, and far below the twenty thousand `TranscriptRowHeights` will
    /// hold, so a session nobody could have read in a week keeps the stepped growth it has today.
    /// Time one entries pass and this can stop being a guess.
    public static let whole = 5_000

    /// Whether a session of this size is drawn in one piece.
    public static func isWhole(rowCount: Int) -> Bool { rowCount <= whole }

    /// The window that holds a whole session.
    public static func everything(rowCount: Int) -> Self { Self(start: 0, end: max(0, rowCount)) }

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
        // Nothing to move the window to, and nothing to grow into. See `whole`.
        if isWhole(rowCount: rowCount) { return everything(rowCount: rowCount) }
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
        if isWhole(rowCount: rowCount) { return everything(rowCount: rowCount) }
        guard window.end >= rowCount else { return window }
        return Self(
            start: min(window.start, clamp(rowCount - settled, rowCount: rowCount)),
            end: max(0, rowCount)
        )
    }

    /// The window grown upward, which is what the reader approaching the top asks for.
    public func grownUp(by chunk: Int = chunk) -> Self {
        Self(start: max(0, start - max(0, chunk)), end: end)
    }

    /// The window grown downward, which is what the reader approaching the bottom of an opened-on-
    /// an-old-row window asks for.
    public func grownDown(rowCount: Int, by chunk: Int = chunk) -> Self {
        Self(start: start, end: min(max(0, rowCount), end + max(0, chunk)))
    }

    /// The window that holds the live end, which is where the jump pill takes the reader.
    ///
    /// The tail rather than everything between here and the end. The reader is being moved to the
    /// newest row, so the rows they were looking at are not rows they are looking at any more, and
    /// realising every one of them on the way is the exact cost `TranscriptTail` was written to
    /// avoid.
    public static func liveEnd(rowCount: Int) -> Self {
        // **A whole session stays whole here, and that is not a detail.** Handing the tail back
        // would take two and a half thousand rows OUT of the list to answer the jump pill, and put
        // every one of them back the moment the reader scrolled up again: a removal, a reload and
        // then the growth this exists to avoid, for a reader who only asked to go to the end.
        if isWhole(rowCount: rowCount) { return everything(rowCount: rowCount) }
        return Self(start: clamp(rowCount - settled, rowCount: rowCount), end: max(0, rowCount))
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

    /// Whether there is any history left above the window to grow into.
    public var canGrowUp: Bool { start > 0 }

    /// Whether the session runs on below the window.
    public func canGrowDown(rowCount: Int) -> Bool { end < rowCount }

    /// How many rows are drawn.
    public var count: Int { max(0, end - start) }

    /// The window clamped to a session, which is what a remembered one has to go through: it was
    /// written down against a row count that may since have grown.
    public func clamped(rowCount: Int) -> Self {
        let end = Self.clamp(self.end, rowCount: rowCount)
        return Self(start: min(Self.clamp(start, rowCount: rowCount), end), end: end)
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
