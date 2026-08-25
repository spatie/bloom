import Foundation
import Testing
@testable import BloomCore

/// How much of a session the list is allowed to hand its lazy stack.
///
/// The arithmetic is here rather than in `TranscriptListView` for the reason the whole split
/// exists: a window worked out inside a view is a window nothing can hold still, and the numbers
/// this returns are the difference between a resize at six frames a second and one at sixty.
@Suite("Transcript window")
struct TranscriptWindowTests {
    // MARK: Opening

    @Test("a session shorter than the tail is drawn whole")
    func shortSessionsAreDrawnWhole() {
        #expect(TranscriptWindow.opening(rowCount: 40, tailStart: 0) == 0)
    }

    @Test("a long session opens on the tail the arrival frame chose")
    func longSessionsOpenOnTheTail() {
        #expect(TranscriptWindow.opening(rowCount: 4_000, tailStart: 3_920) == 3_920)
    }

    @Test("a row that has to be reachable widens the window to hold it, with room above")
    func aTargetWidensTheWindow() {
        let start = TranscriptWindow.opening(rowCount: 4_000, tailStart: 3_920, mustReach: 1_000)
        #expect(start == 1_000 - TranscriptWindow.margin)
    }

    @Test("a target already inside the window leaves it where it was")
    func aTargetInsideChangesNothing() {
        #expect(TranscriptWindow.opening(rowCount: 4_000, tailStart: 3_920, mustReach: 3_990) == 3_920)
    }

    @Test("a target near the top of the session cannot push the window past it")
    func aTargetNearTheTopClamps() {
        #expect(TranscriptWindow.opening(rowCount: 4_000, tailStart: 3_920, mustReach: 3) == 0)
    }

    @Test("a tail longer than the session is clamped to the session")
    func theTailIsClampedToTheSession() {
        #expect(TranscriptWindow.opening(rowCount: 10, tailStart: 80) == 10)
    }

    // MARK: Settling

    @Test("the window settles to a few hundred rows once the arrival is over")
    func settlingHoldsTheSettledLength() {
        let start = TranscriptWindow.settling(from: 3_920, rowCount: 4_000)
        #expect(start == 4_000 - TranscriptWindow.settled)
    }

    @Test("settling never narrows a window that was opened wide for a search result")
    func settlingNeverNarrows() {
        #expect(TranscriptWindow.settling(from: 920, rowCount: 4_000) == 920)
    }

    @Test("a session shorter than the settled length settles at its first row")
    func shortSessionsSettleAtZero() {
        #expect(TranscriptWindow.settling(from: 0, rowCount: 120) == 0)
    }

    // MARK: Growing

    @Test("a growth adds a chunk of history above the window")
    func growthAddsAChunk() {
        #expect(TranscriptWindow.grown(from: 1_000) == 1_000 - TranscriptWindow.chunk)
    }

    @Test("a growth stops at the first row of the session")
    func growthStopsAtTheTop() {
        #expect(TranscriptWindow.grown(from: 100) == 0)
    }

    @Test("a window at the first row has nothing left to grow into")
    func nothingLeftToGrow() {
        #expect(TranscriptWindow.canGrow(from: 0) == false)
        #expect(TranscriptWindow.canGrow(from: 1))
    }

    // MARK: Finding a row

    @Test("a sequence number that is in the session is found where it sits")
    func findsAnExactRow() {
        #expect(TranscriptWindow.index(ofSeqAtOrAfter: 30, in: [0, 10, 20, 30, 40]) == 3)
    }

    @Test("a sequence number with no row of its own lands on the row after it")
    func findsTheRowAfterAGap() {
        #expect(TranscriptWindow.index(ofSeqAtOrAfter: 25, in: [0, 10, 20, 30, 40]) == 3)
    }

    @Test("the first and last rows are both reachable")
    func findsTheEnds() {
        #expect(TranscriptWindow.index(ofSeqAtOrAfter: 0, in: [0, 10, 20]) == 0)
        #expect(TranscriptWindow.index(ofSeqAtOrAfter: 20, in: [0, 10, 20]) == 2)
    }

    @Test("a sequence number past the end of the session is not in it")
    func nothingPastTheEnd() {
        #expect(TranscriptWindow.index(ofSeqAtOrAfter: 99, in: [0, 10, 20]) == nil)
        #expect(TranscriptWindow.index(ofSeqAtOrAfter: 0, in: []) == nil)
    }

    @Test("the answer is an offset from the start, whatever the collection's own indices are")
    func answersAnOffsetNotAnIndex() {
        let rows = [0, 10, 20, 30, 40, 50]
        #expect(TranscriptWindow.index(ofSeqAtOrAfter: 40, in: Array(rows[2...])) == 2)
    }

    @Test("a thousand row session is searched rather than walked")
    func findsInALongSession() {
        let seqs = (0..<1_000).map { $0 * 3 }
        #expect(TranscriptWindow.index(ofSeqAtOrAfter: 1_500, in: seqs) == 500)
        #expect(TranscriptWindow.index(ofSeqAtOrAfter: 1_501, in: seqs) == 501)
    }
}
