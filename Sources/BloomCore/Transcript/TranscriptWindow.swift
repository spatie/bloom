import Foundation

/// How much of a session the list hands to its lazy stack, and when that grows.
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
/// visit paid for four thousand children. This is that second half: the window grows to a few
/// hundred rows once the arrival is over, and grows again when the reader actually approaches the
/// top of it.
///
/// **Nothing here decides what a transcript IS.** `TranscriptModel.rows` is the whole session
/// throughout, which is what the unread counts are computed over and what `TurnScan` walks
/// backwards through. This is a drawing decision and only the list takes it.
public enum TranscriptWindow {
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

    /// How many rows above a row that has to be reachable the window starts.
    ///
    /// A search result opens centred in the pane, so the rows above it have to exist or there is
    /// nothing to centre it against, and an unread mark opens at the top of the pane with the same
    /// need for a little history above it to scroll back into.
    public static let margin = 80

    /// The first row the list draws, as an index into the session's rows.
    ///
    /// `mustReach` is the index of a row the reader has asked for by name, which is a search result
    /// or an unread mark: a scroll can only find a row the list is drawing, so the window is opened
    /// wide enough to hold it whatever the tail said.
    /// A row that is already inside the window leaves it exactly where it was, margin and all: the
    /// margin is what a row ARRIVING in the window brings with it, not a claim about every row.
    public static func opening(rowCount: Int, tailStart: Int, mustReach: Int? = nil) -> Int {
        let start = clamp(tailStart, rowCount: rowCount)
        guard let mustReach, mustReach < start else { return start }
        return clamp(mustReach - margin, rowCount: rowCount)
    }

    /// The window grown upward by one chunk, which is what the reader approaching the top asks for.
    public static func grown(from start: Int, by chunk: Int = chunk) -> Int {
        max(0, start - max(0, chunk))
    }

    /// Where the window settles once the frame that arrived at the session has been drawn.
    ///
    /// Never later than where it already is: a window opened wide because a search result is in it
    /// must not be narrowed a hundred milliseconds later, which would take the row the reader
    /// asked for back off the list.
    public static func settling(from start: Int, rowCount: Int, holding: Int = settled) -> Int {
        min(start, clamp(rowCount - max(0, holding), rowCount: rowCount))
    }

    /// Whether there is any history left above the window to grow into.
    public static func canGrow(from start: Int) -> Bool { start > 0 }

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

    private static func clamp(_ index: Int, rowCount: Int) -> Int {
        min(max(0, index), max(0, rowCount))
    }
}
