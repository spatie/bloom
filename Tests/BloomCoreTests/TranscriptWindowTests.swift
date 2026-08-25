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
        let window = TranscriptWindow.opening(rowCount: 40, tailStart: 0)
        #expect(window == TranscriptWindow(start: 0, end: 40))
    }

    @Test("a long session opens on the tail the arrival frame chose")
    func longSessionsOpenOnTheTail() {
        let window = TranscriptWindow.opening(rowCount: 4_000, tailStart: 3_920)
        #expect(window == TranscriptWindow(start: 3_920, end: 4_000))
    }

    /// The case that forced the window to have a bottom edge. An agent working while nobody is
    /// watching leaves the first unread row near the beginning of a long conversation, and a
    /// window that ran from there to the end was the whole session with extra steps.
    @Test("a session opened on an old row draws that row's neighbourhood, not the rest of the session")
    func anOldTargetDoesNotOpenTheWholeSession() {
        let window = TranscriptWindow.opening(rowCount: 4_000, tailStart: 3_920, mustReach: 100)
        #expect(window.start == 100 - TranscriptWindow.margin)
        #expect(window.end == 100 - TranscriptWindow.margin + TranscriptWindow.margin + TranscriptWindow.settled)
        #expect(window.count < 1_000)
    }

    @Test("a target already inside the tail leaves the window where it was")
    func aTargetInsideChangesNothing() {
        let window = TranscriptWindow.opening(rowCount: 4_000, tailStart: 3_920, mustReach: 3_990)
        #expect(window == TranscriptWindow(start: 3_920, end: 4_000))
    }

    @Test("a target near the top of the session cannot push the window past its first row")
    func aTargetNearTheTopClamps() {
        let window = TranscriptWindow.opening(rowCount: 4_000, tailStart: 3_920, mustReach: 3)
        #expect(window.start == 0)
    }

    @Test("a tail longer than the session is clamped to the session")
    func theTailIsClampedToTheSession() {
        let window = TranscriptWindow.opening(rowCount: 10, tailStart: 80)
        #expect(window == TranscriptWindow(start: 10, end: 10))
    }

    // MARK: Settling

    @Test("the window settles to a few hundred rows once the arrival is over")
    func settlingHoldsTheSettledLength() {
        let settled = TranscriptWindow.settling(
            from: TranscriptWindow(start: 3_920, end: 4_000), rowCount: 4_000
        )
        #expect(settled == TranscriptWindow(start: 4_000 - TranscriptWindow.settled, end: 4_000))
    }

    @Test("settling never narrows a window that was opened wide")
    func settlingNeverNarrows() {
        let settled = TranscriptWindow.settling(
            from: TranscriptWindow(start: 920, end: 4_000), rowCount: 4_000
        )
        #expect(settled == TranscriptWindow(start: 920, end: 4_000))
    }

    @Test("settling leaves a window opened around an old row exactly where it is")
    func settlingLeavesATargetWindow() {
        let opened = TranscriptWindow(start: 20, end: 500)
        #expect(TranscriptWindow.settling(from: opened, rowCount: 4_000) == opened)
    }

    @Test("a session shorter than the settled length settles at its first row")
    func shortSessionsSettleAtZero() {
        let settled = TranscriptWindow.settling(
            from: TranscriptWindow(start: 0, end: 120), rowCount: 120
        )
        #expect(settled == TranscriptWindow(start: 0, end: 120))
    }

    // MARK: Growing

    @Test("a growth upward adds a chunk of history above the window")
    func growthUpAddsAChunk() {
        let grown = TranscriptWindow(start: 1_000, end: 2_000).grownUp()
        #expect(grown == TranscriptWindow(start: 1_000 - TranscriptWindow.chunk, end: 2_000))
    }

    @Test("a growth upward stops at the first row of the session")
    func growthUpStopsAtTheTop() {
        #expect(TranscriptWindow(start: 100, end: 900).grownUp().start == 0)
    }

    @Test("a growth downward adds a chunk of what came after")
    func growthDownAddsAChunk() {
        let grown = TranscriptWindow(start: 0, end: 500).grownDown(rowCount: 4_000)
        #expect(grown == TranscriptWindow(start: 0, end: 500 + TranscriptWindow.chunk))
    }

    @Test("a growth downward stops at the live end")
    func growthDownStopsAtTheEnd() {
        #expect(TranscriptWindow(start: 0, end: 3_900).grownDown(rowCount: 4_000).end == 4_000)
    }

    @Test("a window at both ends of the session has nothing left to grow into")
    func nothingLeftToGrow() {
        let whole = TranscriptWindow(start: 0, end: 100)
        #expect(whole.canGrowUp == false)
        #expect(whole.canGrowDown(rowCount: 100) == false)
        #expect(TranscriptWindow(start: 1, end: 99).canGrowUp)
        #expect(TranscriptWindow(start: 1, end: 99).canGrowDown(rowCount: 100))
    }

    // MARK: The live end

    @Test("the live end is the tail rather than everything between here and it")
    func liveEndIsTheTail() {
        let window = TranscriptWindow.liveEnd(rowCount: 4_000)
        #expect(window == TranscriptWindow(start: 4_000 - TranscriptWindow.settled, end: 4_000))
    }

    @Test("the live end of a short session is the whole of it")
    func liveEndOfAShortSession() {
        #expect(TranscriptWindow.liveEnd(rowCount: 30) == TranscriptWindow(start: 0, end: 30))
    }

    // MARK: Against a session that has moved

    @Test("a remembered window is clamped to the session it is restored into")
    func clampingARememberedWindow() {
        let remembered = TranscriptWindow(start: 3_000, end: 4_000)
        #expect(remembered.clamped(rowCount: 100) == TranscriptWindow(start: 100, end: 100))
        #expect(remembered.clamped(rowCount: 4_200) == remembered)
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
