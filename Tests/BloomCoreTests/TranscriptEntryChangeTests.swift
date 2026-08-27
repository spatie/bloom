import Testing
import Foundation
@testable import BloomCore

@Suite("How a drawn transcript changed")
struct TranscriptEntryChangeTests {
    private func rows(_ seqs: [Int]) -> [TranscriptEntryID] {
        seqs.map { .row($0) }
    }

    /// The list as the pane actually assembles it: the setup log, then the rows, then the bubble
    /// for a message on its way out, then the streaming tail, then the queue. Everything below is
    /// written in this shape rather than in bare rows, because the fixed furniture at both ends is
    /// exactly what the first spelling of this got wrong.
    private func drawn(
        _ seqs: [Int], pending: [String] = []
    ) -> [TranscriptEntryID] {
        [.setup] + rows(seqs) + [.sending, .streaming] + pending.map { .pending(DeliveryID($0)) }
    }

    // MARK: - Nothing moved

    @Test("the same entries in the same order")
    func same() {
        #expect(TranscriptEntryChange.between(drawn([1, 2, 3]), drawn([1, 2, 3])) == .same)
    }

    @Test("two empty lists")
    func bothEmpty() {
        #expect(TranscriptEntryChange.between([TranscriptEntryID](), []) == .same)
    }

    // MARK: - The bug that made all of this dead code

    /// **A row landing at the live end inserts in the MIDDLE of the list**, because the streaming
    /// tail is always after it. Asked whether the old list is a contiguous block of the new one,
    /// the answer is no, and the table reloaded everything on every single row that arrived. This
    /// is the test that fails against that spelling.
    @Test("a row landing at the live end is one insertion, not a rebuild")
    func aRowLandingIsNotARebuild() {
        let old = drawn(Array(0..<100))
        let new = drawn(Array(0..<101))
        #expect(TranscriptEntryChange.between(old, new) == .grew(head: 101..<102, tail: 0..<0))
    }

    /// And the mirror: history going in above the reader, with the setup log still at index 0.
    @Test("history put in above the reader, under the setup log")
    func historyIsNotARebuild() {
        let old = drawn([5, 6, 7])
        let new = drawn([1, 2, 3, 4, 5, 6, 7])
        #expect(TranscriptEntryChange.between(old, new) == .grew(head: 1..<5, tail: 0..<0))
    }

    /// A queued message going on the end, behind the streaming tail.
    @Test("a queued message put on the end")
    func queuedMessage() {
        let old = drawn([1, 2], pending: ["a"])
        let new = drawn([1, 2], pending: ["a", "b"])
        #expect(TranscriptEntryChange.between(old, new) == .grew(head: 6..<7, tail: 0..<0))
    }

    // MARK: - Rows arriving

    @Test("both ends at once")
    func grewAtBothEnds() {
        let old = drawn([5, 6])
        let new = drawn([3, 4, 5, 6, 7])
        #expect(TranscriptEntryChange.between(old, new) == .grew(head: 1..<3, tail: 5..<6))
    }

    /// The very first pass: an empty table filled. Rows in rather than a reload, which matters
    /// because a reload on the first pass is a reload the arrival frame pays for.
    @Test("a list filled from nothing")
    func filled() {
        #expect(
            TranscriptEntryChange.between([], rows([1, 2, 3])) == .grew(head: 0..<3, tail: 0..<0)
        )
    }

    // MARK: - Rows leaving

    /// The jump pill moving the window to the tail, which drops everything above it.
    @Test("the window moved to the tail")
    func shrankAtTheHead() {
        let old = drawn([1, 2, 3, 4, 5])
        let new = drawn([4, 5])
        #expect(TranscriptEntryChange.between(old, new) == .shrank(head: 1..<4, tail: 0..<0))
    }

    @Test("a queued message sent")
    func shrankAtTheTail() {
        let old = drawn([1, 2, 3], pending: ["a", "b"])
        let new = drawn([1, 2, 3], pending: ["a"])
        #expect(TranscriptEntryChange.between(old, new) == .shrank(head: 7..<8, tail: 0..<0))
    }

    @Test("a whole list emptied")
    func emptied() {
        #expect(
            TranscriptEntryChange.between(rows([1, 2, 3]), []) == .shrank(head: 0..<3, tail: 0..<0)
        )
    }

    @Test("both ends taken away at once")
    func shrankAtBothEnds() {
        let old = drawn([3, 4, 5, 6, 7])
        let new = drawn([5, 6])
        #expect(TranscriptEntryChange.between(old, new) == .shrank(head: 1..<3, tail: 5..<6))
    }

    // MARK: - Anything else

    /// A session being replaced. Every cell is thrown away, and nothing else in the app should
    /// ever reach this case.
    @Test("an unrelated list is a rebuild")
    func rebuilt() {
        #expect(TranscriptEntryChange.between(drawn([1, 2, 3]), drawn([9, 10, 11, 12])) == .rebuilt)
    }

    @Test("the same number of different rows is a rebuild")
    func sameLengthDifferentRows() {
        #expect(TranscriptEntryChange.between(rows([1, 2, 3]), rows([4, 5, 6])) == .rebuilt)
    }

    /// A row seq that repeats cannot happen in one session, but the run has to be checked whole
    /// before it is believed, or a growth would put rows at the wrong indices.
    @Test("a repeated id does not fool the run search")
    func repeatedID() {
        let old = rows([2, 3, 4, 3])
        let new = rows([2, 9, 9, 3, 4, 3])
        #expect(TranscriptEntryChange.between(old, new) == .grew(head: 1..<3, tail: 0..<0))
    }

    // MARK: - What the caller does with it

    @Test("only a change of shape moves anything under the reader")
    func movesRows() {
        #expect(!TranscriptEntryChange.same.movesRows)
        #expect(TranscriptEntryChange.grew(head: 1..<5, tail: 0..<0).movesRows)
        #expect(TranscriptEntryChange.shrank(head: 1..<4, tail: 0..<0).movesRows)
        #expect(TranscriptEntryChange.rebuilt.movesRows)
    }

    /// Every index a growth names is an index into the NEW list, and every index a shrink names is
    /// an index into the OLD one, which is what makes them safe to hand straight to
    /// `insertRows(at:)` and `removeRows(at:)`. Rebuilding the list from them is the check.
    @Test("a growth's indices rebuild the new list from the old one")
    func indicesAreUsable() {
        let old = drawn([5, 6])
        let new = drawn([3, 4, 5, 6, 7])
        guard case .grew(let head, let tail) = TranscriptEntryChange.between(old, new) else {
            Issue.record("expected a growth")
            return
        }
        var rebuilt = old
        for index in head { rebuilt.insert(new[index], at: index) }
        for index in tail { rebuilt.insert(new[index], at: index) }
        #expect(rebuilt == new)
    }

    // MARK: - Folding a run of tool calls

    /// **The whole reason `TranscriptFold` is shaped the way it is, written down as the shapes it
    /// has to produce.** Every one of these must be a single contiguous edit: `.rebuilt` is a
    /// `reloadData()`, which throws away every cell and the reader's text selection, and a fold
    /// that cost one of those per tool call would be far slower than no fold at all. The runs are
    /// therefore held in the list's own state and refreshed one pass BEHIND the rows, so a call
    /// landing and the fold that swallows it are never the same pass.
    ///
    /// The run here begins at row 10, and `fold.10` is the line above it.
    private func withFold(_ seqs: [Int]) -> [TranscriptEntryID] {
        [.setup, .fold(10)] + rows(seqs) + [.sending, .streaming]
    }

    /// A group's line joins the list at its second call, long before it can fold. That gap is what
    /// makes every shape below a single edit: an entry appearing on the same pass that rows leave
    /// is an insertion and a removal at once, and there is no answer to that but `.rebuilt`.
    @Test("a run's line goes in while the run is far too short to fold")
    func theFoldLineArrives() {
        let old = drawn([10])
        let new = withFold([10, 11])
        #expect(TranscriptEntryChange.between(old, new) == .grew(head: 1..<2, tail: 3..<4))
    }

    /// **The pass a run first folds is a removal and nothing else**, because the line was already
    /// there and the newest call, which is the row the fold keeps, does not move.
    @Test("a run reaching four calls folds by taking three rows out")
    func foldingIsOneRemoval() {
        let open = withFold([10, 11, 12, 13])
        let folded = withFold([13])
        #expect(TranscriptEntryChange.between(open, folded) == .shrank(head: 2..<5, tail: 0..<0))
    }

    /// **And the shape that repeats for every call after that, which is the one folding on arrival
    /// added.** The call lands on its own pass and the fold swallows the one before it on the
    /// next, so the transcript stops growing during a run: one row in, one row out, and the line
    /// above them counting up.
    @Test("a call landing in a folded run, then the fold swallowing the one before it")
    func aCallLandsIntoAFoldedRun() {
        let folded = withFold([13])
        let landed = withFold([13, 14])
        #expect(TranscriptEntryChange.between(folded, landed) == .grew(head: 3..<4, tail: 0..<0))
        let swallowed = withFold([14])
        #expect(TranscriptEntryChange.between(landed, swallowed) == .shrank(head: 2..<3, tail: 0..<0))
    }

    /// Opening a fold is the mirror of closing it. The line stays put and the rows go back in
    /// behind it, which is what naming the fold by the run's FIRST call buys.
    @Test("opening a fold puts its rows back in one run")
    func unfoldingIsOneInsertion() {
        let folded = withFold([13])
        let open = withFold([10, 11, 12, 13])
        #expect(TranscriptEntryChange.between(folded, open) == .grew(head: 2..<5, tail: 0..<0))
        #expect(TranscriptEntryChange.between(open, folded) == .shrank(head: 2..<5, tail: 0..<0))
    }

    /// A burst of parallel calls arrives with no results back, so nothing may be hidden yet: the
    /// pass that discovers the run only puts its line in.
    @Test("a burst of calls with no results back is an insertion and no fold")
    func aParallelBurstDoesNotFold() {
        let old = drawn([])
        let landed = drawn([10, 11, 12, 13])
        #expect(TranscriptEntryChange.between(old, landed) == .grew(head: 1..<5, tail: 0..<0))
        let listed = withFold([10, 11, 12, 13])
        #expect(TranscriptEntryChange.between(landed, listed) == .grew(head: 1..<2, tail: 0..<0))
    }

    /// **And the shape that would happen if the runs were computed in the body rather than held
    /// one pass behind it.** Here so that anybody who moves them back finds out from a test rather
    /// than from a scroll.
    @Test("a call landing and a run folding on one pass is a rebuild")
    func bothAtOnceIsARebuild() {
        let running = withFold([10, 11, 12, 13])
        let landedAndFolded = withFold([14])
        #expect(TranscriptEntryChange.between(running, landedAndFolded) == .rebuilt)
    }

    // MARK: - The five kinds of entry

    /// A delivery and a row must never be spelled into each other however the two lists grow,
    /// which is what the typed id buys and is worth one test.
    @Test("a delivery and a row are never the same entry")
    func kindsAreDistinct() {
        #expect(TranscriptEntryID.row(1).seq == 1)
        #expect(TranscriptEntryID.streaming.seq == nil)
        #expect(TranscriptEntryID.setup != TranscriptEntryID.streaming)
        #expect(TranscriptEntryID.pending(DeliveryID("1")) != TranscriptEntryID.row(1))
        // A run's line and the first row of that run hold the same number and are in the list at
        // the same time.
        #expect(TranscriptEntryID.fold(1) != TranscriptEntryID.row(1))
    }
}
