import Foundation
import Testing
@testable import BloomCore

/// How much of a session the list draws.
///
/// The arithmetic is here rather than in `TranscriptListView` for the reason the whole split
/// exists: a window worked out inside a view is a window nothing can hold still.
///
/// **The fixtures below use eight thousand rows where they used four.** Four thousand is drawn in
/// one piece now, so a test that meant "a long session" has to name one past the ceiling or it
/// quietly stops testing the stepped growth it was written for. See `TranscriptWindow.whole`.
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
        let window = TranscriptWindow.opening(rowCount: 8_000, tailStart: 7_920)
        #expect(window == TranscriptWindow(start: 7_920, end: 8_000))
    }

    /// The case that forced the window to have a bottom edge. An agent working while nobody is
    /// watching leaves the first unread row near the beginning of a long conversation, and a
    /// window that ran from there to the end was the whole session with extra steps.
    @Test("a session opened on an old row draws that row's neighbourhood, not the rest of the session")
    func anOldTargetDoesNotOpenTheWholeSession() {
        let window = TranscriptWindow.opening(rowCount: 8_000, tailStart: 7_920, mustReach: 100)
        #expect(window.start == 100 - TranscriptWindow.margin)
        #expect(window.end == 100 - TranscriptWindow.margin + TranscriptWindow.margin + TranscriptWindow.settled)
        #expect(window.count < 1_000)
    }

    @Test("a target already inside the tail leaves the window where it was")
    func aTargetInsideChangesNothing() {
        let window = TranscriptWindow.opening(rowCount: 8_000, tailStart: 7_920, mustReach: 7_990)
        #expect(window == TranscriptWindow(start: 7_920, end: 8_000))
    }

    @Test("a target near the top of the session cannot push the window past its first row")
    func aTargetNearTheTopClamps() {
        let window = TranscriptWindow.opening(rowCount: 8_000, tailStart: 7_920, mustReach: 3)
        #expect(window.start == 0)
    }

    /// It used to answer an EMPTY window here, because the tail was clamped to the session and
    /// landed on its last row. Ten rows are drawn whole now, which is both the better answer and
    /// the one every other case gives.
    @Test("a tail longer than the session draws the session")
    func theTailIsClampedToTheSession() {
        let window = TranscriptWindow.opening(rowCount: 10, tailStart: 80)
        #expect(window == TranscriptWindow(start: 0, end: 10))
    }

    // MARK: Settling

    @Test("the window settles to a few hundred rows once the arrival is over")
    func settlingHoldsTheSettledLength() {
        let settled = TranscriptWindow.settling(
            from: TranscriptWindow(start: 7_920, end: 8_000), rowCount: 8_000
        )
        #expect(settled == TranscriptWindow(start: 8_000 - TranscriptWindow.settled, end: 8_000))
    }

    @Test("settling never narrows a window that was opened wide")
    func settlingNeverNarrows() {
        let settled = TranscriptWindow.settling(
            from: TranscriptWindow(start: 4_920, end: 8_000), rowCount: 8_000
        )
        #expect(settled == TranscriptWindow(start: 4_920, end: 8_000))
    }

    @Test("settling leaves a window opened around an old row exactly where it is")
    func settlingLeavesATargetWindow() {
        let opened = TranscriptWindow(start: 20, end: 500)
        #expect(TranscriptWindow.settling(from: opened, rowCount: 8_000) == opened)
    }

    // MARK: Drawn whole

    /// **The window exists for a `LazyVStack` that this app no longer draws with.** Under a table
    /// what a window costs is the arriving: a growth rebuilds every entry the list holds and
    /// inserts four hundred rows on a frame the reader is scrolling through. See
    /// `TranscriptWindow.whole`.
    @Test("a session inside the ceiling is drawn whole from the first frame")
    func aWholeSessionOpensWhole() {
        let rows = TranscriptWindow.whole
        let window = TranscriptWindow.opening(rowCount: rows, tailStart: rows - 80)
        #expect(window == TranscriptWindow(start: 0, end: rows))
        #expect(window.canGrowUp == false)
        #expect(window.canGrowDown(rowCount: rows) == false)
    }

    /// A row asked for by name is already in the list, so nothing has to move to reach it.
    @Test("a whole session needs no window moved to reach an old row")
    func aWholeSessionReachesEveryRow() {
        let window = TranscriptWindow.opening(rowCount: 3_000, tailStart: 2_920, mustReach: 4)
        #expect(window == TranscriptWindow(start: 0, end: 3_000))
    }

    /// **The jump pill must not take the session apart.** Handing the tail back here would remove
    /// every row above it from the list and put them all back on the next scroll upwards.
    @Test("the live end of a whole session is still the whole session")
    func liveEndKeepsAWholeSession() {
        #expect(TranscriptWindow.liveEnd(rowCount: 3_000) == TranscriptWindow(start: 0, end: 3_000))
    }

    @Test("settling a whole session leaves it whole")
    func settlingAWholeSession() {
        let settled = TranscriptWindow.settling(
            from: TranscriptWindow(start: 2_600, end: 3_000), rowCount: 3_000
        )
        #expect(settled == TranscriptWindow(start: 0, end: 3_000))
    }

    /// A session past the ceiling keeps every bit of the stepped growth, because the cost that
    /// justifies the ceiling is the pass that assembles one entry per row in the window.
    @Test("a session past the ceiling still opens on its tail")
    func pastTheCeilingIsWindowed() {
        let rows = TranscriptWindow.whole + 1
        let window = TranscriptWindow.opening(rowCount: rows, tailStart: rows - 80)
        #expect(window == TranscriptWindow(start: rows - 80, end: rows))
        #expect(window.canGrowUp)
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
        let grown = TranscriptWindow(start: 0, end: 500).grownDown(rowCount: 8_000)
        #expect(grown == TranscriptWindow(start: 0, end: 500 + TranscriptWindow.chunk))
    }

    @Test("a growth downward stops at the live end")
    func growthDownStopsAtTheEnd() {
        #expect(TranscriptWindow(start: 0, end: 7_900).grownDown(rowCount: 8_000).end == 8_000)
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
        let window = TranscriptWindow.liveEnd(rowCount: 8_000)
        #expect(window == TranscriptWindow(start: 8_000 - TranscriptWindow.settled, end: 8_000))
    }

    @Test("the live end of a short session is the whole of it")
    func liveEndOfAShortSession() {
        #expect(TranscriptWindow.liveEnd(rowCount: 30) == TranscriptWindow(start: 0, end: 30))
    }

    // MARK: Against a session that has moved

    @Test("a remembered window is clamped to the session it is restored into")
    func clampingARememberedWindow() {
        let remembered = TranscriptWindow(start: 7_000, end: 8_000)
        #expect(remembered.clamped(rowCount: 100) == TranscriptWindow(start: 100, end: 100))
        #expect(remembered.clamped(rowCount: 8_200) == remembered)
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

    // MARK: The order a preparation pass takes the window in

    /// A session opened on its live end is read from the bottom, so the bottom is what has to be
    /// ready first. See `TranscriptPrime`.
    @Test("a window anchored at its end is prepared from the end")
    func preparesTheLiveEndFirst() {
        let window = TranscriptWindow(start: 0, end: 5)
        #expect(window.indices(outwardFrom: 4) == [4, 3, 2, 1, 0])
    }

    @Test("a window anchored on an unread row is prepared outwards from it")
    func preparesAroundTheUnreadRow() {
        let window = TranscriptWindow(start: 0, end: 5)
        let order = window.indices(outwardFrom: 2)
        #expect(order.first == 2)
        #expect(Set(order.prefix(3)) == [1, 2, 3])
        #expect(Set(order) == Set(0..<5))
    }

    @Test("an anchor outside the window is pulled to its nearer edge")
    func clampsTheAnchor() {
        #expect(TranscriptWindow(start: 10, end: 20).indices(outwardFrom: 0).first == 10)
        #expect(TranscriptWindow(start: 10, end: 20).indices(outwardFrom: 99).first == 19)
    }

    @Test("an empty window is nothing to prepare")
    func preparesNothingForAnEmptyWindow() {
        #expect(TranscriptWindow(start: 0, end: 0).indices(outwardFrom: 0).isEmpty)
    }
}
