import Testing
@testable import BloomCore

/// Reported as: a new item appears under the group for a split second, and then joins it. That
/// frame is the pass the runs are refreshed on, one behind the row that changed them. See
/// `TranscriptFold.mayAdopt`, which says which of those passes can be brought forward.
@Suite("Folding on the pass the row arrived")
struct TranscriptFoldAdoptionTests {
    private static func work(
        firstSeq: Int, rows: Int, ready: Int, upperBound: Int? = nil
    ) -> TranscriptFold.Work {
        let list = (0..<rows).map { TranscriptFold.Row(index: $0, seq: firstSeq + $0) }
        return TranscriptFold.Work(
            span: 0..<(upperBound ?? rows), rows: list, ready: ready, hasAnswer: false
        )
    }

    private static func folds(_ all: [TranscriptFold.Work]) -> TranscriptFold.Folds {
        TranscriptFold.Folds(all: all, scannedRows: 0, resumeIndex: 0)
    }

    /// The one the report is about: a call's result lands, the call settles, and nothing takes its
    /// place in the tail. That is a removal whichever pass it happens on, so it happens on this one.
    @Test func adoptsAPassThatOnlyTakesRowsOutOfTheTail() {
        let stale = Self.folds([Self.work(firstSeq: 10, rows: 4, ready: 3)])
        let fresh = Self.folds([Self.work(firstSeq: 10, rows: 4, ready: 4)])

        #expect(TranscriptFold.mayAdopt(fresh, over: stale, drawn: 0..<40))
    }

    /// The batched case, and the reason the deferral exists: a result and the next call arrive
    /// together, so the exposed row is replaced rather than removed. A middle of the same length
    /// with different ids is the `.rebuilt` that throws away every cell.
    @Test func refusesAPassThatPutsANewRowInTheTail() {
        let stale = Self.folds([Self.work(firstSeq: 10, rows: 4, ready: 3)])
        let fresh = Self.folds([Self.work(firstSeq: 10, rows: 5, ready: 4)])

        #expect(!TranscriptFold.mayAdopt(fresh, over: stale, drawn: 0..<40))
    }

    /// A plain arrival with nothing settling is an insertion, which the deferred pass already
    /// handles as a `.grew` on its own. Nothing is gained by bringing it forward.
    @Test func refusesAPlainArrival() {
        let stale = Self.folds([Self.work(firstSeq: 10, rows: 4, ready: 4)])
        let fresh = Self.folds([Self.work(firstSeq: 10, rows: 5, ready: 4)])

        #expect(!TranscriptFold.mayAdopt(fresh, over: stale, drawn: 0..<40))
    }

    /// A turn's first fold is an entry appearing in the middle of the list, which is the one shape
    /// `Folds` documents as a reload.
    @Test func refusesAFoldThatDidNotExistYet() {
        let stale = Self.folds([])
        let fresh = Self.folds([Self.work(firstSeq: 10, rows: 4, ready: 4)])

        #expect(!TranscriptFold.mayAdopt(fresh, over: stale, drawn: 0..<40))
    }

    /// **`hides` refuses to fold a working the drawn window stops inside**, so adopting one whose
    /// rows the table is not all holding would unfold the turn for a pass, which is the opposite
    /// of the complaint. The window grows on the same event and one pass behind, exactly as the
    /// runs do.
    @Test func refusesAWorkingThatRunsPastTheDrawnWindow() {
        let stale = Self.folds([Self.work(firstSeq: 10, rows: 4, ready: 3, upperBound: 4)])
        let fresh = Self.folds([Self.work(firstSeq: 10, rows: 4, ready: 4, upperBound: 41)])

        #expect(!TranscriptFold.mayAdopt(fresh, over: stale, drawn: 0..<40))
    }

    /// A session replaced under the list is not an append, and nothing here may treat it as one.
    @Test func refusesADifferentTurnAltogether() {
        let stale = Self.folds([Self.work(firstSeq: 10, rows: 4, ready: 3)])
        let fresh = Self.folds([Self.work(firstSeq: 99, rows: 4, ready: 4)])

        #expect(!TranscriptFold.mayAdopt(fresh, over: stale, drawn: 0..<40))
    }
}
