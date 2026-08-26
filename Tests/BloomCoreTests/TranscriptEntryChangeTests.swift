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

    // MARK: - The five kinds of entry

    /// A delivery and a row must never be spelled into each other however the two lists grow,
    /// which is what the typed id buys and is worth one test.
    @Test("a delivery and a row are never the same entry")
    func kindsAreDistinct() {
        #expect(TranscriptEntryID.row(1).seq == 1)
        #expect(TranscriptEntryID.streaming.seq == nil)
        #expect(TranscriptEntryID.setup != TranscriptEntryID.streaming)
        #expect(TranscriptEntryID.pending(DeliveryID("1")) != TranscriptEntryID.row(1))
    }
}
