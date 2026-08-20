import Foundation

/// How much of a transcript the list draws on the frame that arrives at a workspace.
///
/// A session opens on its live end, and resolving a position at the end of a `LazyVStack` costs a
/// layout of every row above it: measured on a release build, 24ms over forty rows, 75ms over two
/// hundred and 269ms over four thousand. That cost is the whole of the wait between clicking a
/// workspace in the sidebar and seeing it, and it is paid for rows that are thousands of points
/// above the viewport and will never be looked at.
///
/// So the arrival frame is laid out over the end of the session only, and the rest of the history
/// is put back a moment later, under the list's own bottom anchor for size changes, which holds
/// everything on screen exactly where it is while the content grows above it.
///
/// This says nothing about what a transcript IS. `TranscriptModel.rows` stays the whole session at
/// all times, which is what the unread counts read and what `TurnScan` walks backwards through, and
/// both would be wrong over a partial one.
public enum TranscriptTail {
    /// How many rows the arrival frame draws.
    ///
    /// At the smallest pitch a transcript row is drawn at, this is around three screens of a full
    /// height window, so the view can be put on the live end with room above it and a flick of the
    /// wheel still lands inside it. Costed at roughly what a forty row session costs, which is the
    /// floor: below about this many rows the layout is the pane's own fixed cost rather than the
    /// rows in it, and shortening it further buys nothing.
    public static let length = 80

    /// The first row the arrival frame draws, as an index into the session's rows.
    ///
    /// Zero for anything short enough to draw whole, so a session under the tail length behaves
    /// exactly as it always has and no session is ever drawn in two pieces without needing to be.
    ///
    /// The cut is nudged up to the row after the last completed turn, so what the tail holds is a
    /// whole number of turns rather than the back half of one. Only as far as the tail's own length
    /// again: a single turn longer than that is not worth doubling the arrival frame for, and the
    /// history is on its way regardless.
    public static func start(in kinds: [MessageKind], length: Int = length) -> Int {
        guard length > 0, kinds.count > length else { return 0 }

        let cut = kinds.count - length
        let reach = max(0, cut - length)
        var index = cut
        while index > reach {
            // A turn ends on its result row, so the row after one begins the next turn.
            if kinds[index - 1] == .result { return index }
            index -= 1
        }
        return cut
    }
}
