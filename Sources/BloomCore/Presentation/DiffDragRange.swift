import Foundation

/// How far down a diff a drag from one line's gutter control has reached.
///
/// **Asked for: dragging across several lines to comment on the range.** The `+` in the gutter
/// opens the comment editor on the line it sits beside; held and dragged, it should select the
/// lines it is dragged over, the way a review on the web does.
///
/// It is arithmetic on a row height rather than a hit test, and both halves of that are forced.
/// Most rows of a diff are drawn as a `DiffRunView`, several lines in one selectable text object
/// with a column of chrome beside it, so there is no per line view under the pointer to ask. And
/// every line box in a run is exactly `CodeMetrics.rowHeight` tall, which is the invariant that
/// view already depends on for its hover and its gutter, so counting rows off the translation is
/// as true as asking would be.
///
/// **The offset is rounded rather than truncated, and that is about where the drag starts.** The
/// gesture is carried by the `+` button, which is centred in its own row, so a pointer that has
/// travelled half a row height is standing on the boundary between two of them and a further
/// pixel puts it in the next. Truncating would mean a whole row of travel before the selection
/// moved, which reads as the drag being stuck.
///
/// **A drag is clamped to the block it began in**, which the caller enforces by handing over the
/// count of rows it has. A block ends at anything that is not a line of code: a hunk heading, an
/// expander, a comment band, the open editor. Stopping there rather than guessing what is on the
/// other side is the safe half of the trade, because the lines beyond a heading are not
/// consecutive with the ones before it and a range that leapt over one would be a note about a
/// stretch of file that does not exist. What the reader sees tinted is what they get, so a
/// selection that stops short says so on screen while it is still a drag.
public enum DiffDragRange {
    /// - Parameters:
    ///   - start: the row the drag began on, as an offset into the block.
    ///   - translation: how far the pointer has moved vertically, in points, positive downwards.
    ///   - rowHeight: the height of one line box.
    ///   - count: how many rows the block holds.
    /// - Returns: the row the drag is over now, clamped into the block.
    public static func row(
        from start: Int,
        translation: CGFloat,
        rowHeight: CGFloat,
        count: Int
    ) -> Int {
        guard count > 0 else { return 0 }
        guard rowHeight > 0 else { return min(max(start, 0), count - 1) }
        let moved = Int((translation / rowHeight).rounded())
        return min(max(start + moved, 0), count - 1)
    }

    /// Which line of the diff a drag has reached, given what each row of the block offers.
    ///
    /// A row can offer nothing (the padding opposite a longer run in the split layout, the "no
    /// newline" row) or offer the other side of the diff (a deletion, while the drag began on the
    /// new side). Both are stepped back over, towards the row the drag began on, until a row on
    /// the drag's own side is found. **They are stepped over rather than ending the range**,
    /// because a deletion sitting between two added lines in a unified diff is exactly the shape
    /// a reviewer drags across, and a range is a run of line numbers on one side rather than a
    /// run of rows on screen.
    ///
    /// - Parameters:
    ///   - spots: what each row of the block anchors to, in drawn order, already filtered to the
    ///     pane it belongs to the way `DiffCommentSpot` filters it.
    ///   - side: the side the drag began on. A range never crosses between the two: the old side
    ///     is the merge base's copy of the file and the new side is the worktree's.
    /// - Returns: the line the range now ends at, or nil when no row between the start and the
    ///   pointer answers for that side, which the caller reads as "leave the range as it was".
    /// Hit a logical source line after wrapping has given rows different heights.
    public static func row(at offset: CGFloat, heights: [CGFloat]) -> Int? {
        guard offset >= 0, offset.isFinite else { return nil }
        var end: CGFloat = 0
        for (index, height) in heights.enumerated() {
            end += height
            if offset < end { return index }
        }
        return nil
    }

    public static func spot(
        from start: Int,
        translation: CGFloat,
        rowHeight: CGFloat,
        rowHeights: [CGFloat]? = nil,
        spots: [ReviewSpot?],
        side: ReviewCommentSide
    ) -> ReviewSpot? {
        let target: Int
        if let rowHeights, rowHeights.count == spots.count, rowHeights.indices.contains(start) {
            let y = rowHeights.prefix(start).reduce(0, +) + rowHeight / 2 + translation
            target = row(at: max(0, y), heights: rowHeights) ?? max(0, spots.count - 1)
        } else {
            target = row(from: start, translation: translation, rowHeight: rowHeight, count: spots.count)
        }
        guard spots.indices.contains(target), spots.indices.contains(start) else { return nil }
        let step = target >= start ? -1 : 1
        var index = target
        while spots.indices.contains(index) {
            if let spot = spots[index], spot.side == side { return spot }
            if index == start { return nil }
            index += step
        }
        return nil
    }
}
