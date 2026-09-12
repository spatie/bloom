import Foundation

/// How a new list of drawn transcript entries differs from the one already on screen.
///
/// **It exists because `reloadData()` is the whole of a scroll stall.** A reload throws every cell
/// away and builds the visible ones again, which for a transcript is a dozen hosting views laying
/// out markdown, text views and chips from nothing. The window grows by four hundred rows at a
/// time and does it while the reader is scrolling, so a sweep down a long conversation paid that
/// several times: measured at a median frame of 19.8ms with a p99 of a full second, against 8.3ms
/// and 25ms for the lazy stack the table replaced. A reload also takes the reader's text selection
/// with it, because the `NSTextView` inside the cell goes when the cell does. Told which rows
/// arrived, the table leaves every cell it already has alone.
///
/// **Only the edges of the ROWS ever move, which is not the same as the edges of the list, and
/// getting that wrong made the whole mechanism dead code.** `TranscriptWindow` grows by a chunk at
/// the top when the reader nears it and by a chunk at the bottom when they near that; rows are
/// appended at the live end and never reordered. But the list handed to the table is not the rows:
/// it is `setup`, then the rows, then the bubble for a message on its way out, then the streaming
/// tail, then the queue. So a row landing at the live end inserts in the MIDDLE of the list, and
/// the first spelling of this asked whether the old list was a contiguous block of the new one,
/// which for `[setup, r0…r99, streaming]` inside `[setup, r0…r100, streaming]` is false: the run
/// breaks at `streaming`. Every arrival therefore answered `.rebuilt` and every arrival was a full
/// reload, which is precisely the cost the type was written to avoid.
///
/// So the comparison starts by eating the common prefix and the common suffix, which takes the
/// fixed furniture at both ends out of the question, and only then asks what happened in the
/// middle. Three symbols out the other side, each named so that the next `sample` during a scroll
/// can tell which branch was taken.
public enum TranscriptEntryChange: Equatable, Sendable {
    /// The same entries in the same order. Only their content can have moved.
    case same
    /// Entries put in, at these two runs of indices into the NEW list. Either can be empty.
    ///
    /// Two runs because one pass can add at both ends of the rows at once: the window grown
    /// upwards for a reader near the top, while a turn appends at the live end.
    case grew(head: Range<Int>, tail: Range<Int>)
    /// Entries taken out, at these two runs of indices into the OLD list. Either can be empty.
    case shrank(head: Range<Int>, tail: Range<Int>)
    /// Anything else, which in practice is a session being replaced.
    case rebuilt

    /// Whether anything moved under the reader, and therefore whether their place has to be kept.
    ///
    /// `.same` is the pass where only an entry's own content changed, and content changing in
    /// place moves nothing above it.
    public var movesRows: Bool { self != .same }

    public static func between<ID: Equatable>(_ old: [ID], _ new: [ID]) -> Self {
        // The fixed furniture at both ends, eaten before anything is asked about the middle. See
        // the header: this is the whole of what the first spelling got wrong.
        let shortest = min(old.count, new.count)
        var head = 0
        while head < shortest, old[head] == new[head] { head += 1 }
        var tail = 0
        while tail < shortest - head,
              old[old.count - 1 - tail] == new[new.count - 1 - tail] { tail += 1 }

        let oldMiddle = head..<(old.count - tail)
        let newMiddle = head..<(new.count - tail)

        if oldMiddle.isEmpty, newMiddle.isEmpty { return .same }
        // Everything that differs is an insertion, or everything that differs is a removal. The
        // ordinary cases: a row landing, a chunk of history going in above, the window moving to
        // the tail, a queued message sent.
        if oldMiddle.isEmpty { return .grew(head: newMiddle, tail: 0..<0) }
        if newMiddle.isEmpty { return .shrank(head: oldMiddle, tail: 0..<0) }

        // Both ends moved at once. The old middle has to sit inside the new one whole and
        // unbroken, or the other way about, and it can be neither at the head nor at the tail of
        // it, since the trimming above would have eaten it.
        if newMiddle.count > oldMiddle.count,
           let at = start(of: old[oldMiddle], in: new[newMiddle]) {
            let inner = newMiddle.lowerBound + at
            return .grew(
                head: newMiddle.lowerBound..<inner,
                tail: (inner + oldMiddle.count)..<newMiddle.upperBound
            )
        }
        if oldMiddle.count > newMiddle.count,
           let at = start(of: new[newMiddle], in: old[oldMiddle]) {
            let inner = oldMiddle.lowerBound + at
            return .shrank(
                head: oldMiddle.lowerBound..<inner,
                tail: (inner + newMiddle.count)..<oldMiddle.upperBound
            )
        }
        return .rebuilt
    }

    /// How far into `outer` the whole of `inner` sits, unbroken, or nothing.
    ///
    /// The run is checked whole rather than trusted from its first element, so a repeated id
    /// cannot fool it into reporting a growth that would put rows in the wrong place.
    private static func start<ID: Equatable>(
        of inner: ArraySlice<ID>, in outer: ArraySlice<ID>
    ) -> Int? {
        guard let first = inner.first, outer.count >= inner.count else { return nil }
        for offset in 0...(outer.count - inner.count) {
            let at = outer.startIndex + offset
            guard outer[at] == first else { continue }
            var matches = true
            for step in 0..<inner.count where outer[at + step] != inner[inner.startIndex + step] {
                matches = false
                break
            }
            if matches { return offset }
        }
        return nil
    }
}
