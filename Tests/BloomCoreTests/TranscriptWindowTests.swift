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
    @Test func savedMessageIsPresentWhenItsEchoIsRemoved() {
        let drawn = TranscriptWindow(start: 20, end: 100)
        let firstPass = drawn.includingAppendedRows(previousCount: 100, rowCount: 101)
        #expect(firstPass == TranscriptWindow(start: 20, end: 101))
        #expect((firstPass.start..<firstPass.end).contains(100))
    }

    @Test func appendingDoesNotOpenHistoryWindowsToTheLiveEnd() {
        let drawn = TranscriptWindow(start: 20, end: 100)
        #expect(drawn.includingAppendedRows(previousCount: 200, rowCount: 201) == drawn)
    }

    @Test func appendWindowHandlesEmptyAndReloadedTranscripts() {
        #expect(TranscriptWindow(start: 0, end: 0)
            .includingAppendedRows(previousCount: 0, rowCount: 1) == TranscriptWindow(start: 0, end: 1))
        #expect(TranscriptWindow(start: 20, end: 100)
            .includingAppendedRows(previousCount: 100, rowCount: 10) == TranscriptWindow(start: 10, end: 10))
    }

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

    @Test("idle preparation adds one bounded chunk after the session has arrived")
    func idlePreparationAddsAChunk() {
        let window = TranscriptWindow(start: 1_000, end: 2_000)
        #expect(
            window.preparedHistory(afterArrival: true)
                == TranscriptWindow(start: 1_000 - TranscriptWindow.chunk, end: 2_000)
        )
    }

    @Test("idle preparation waits for the session to finish arriving")
    func idlePreparationWaitsForArrival() {
        let window = TranscriptWindow(start: 1_000, end: 2_000)
        #expect(window.preparedHistory(afterArrival: false) == nil)
    }

    @Test("live-end preparation stops at its row budget")
    func livePreparationStaysBounded() {
        let window = TranscriptWindow(start: 4_000, end: 5_000)
        let prepared = window.preparedHistory(
            afterArrival: true, maximumRows: TranscriptWindow.livePreparedLimit
        )
        #expect(prepared == TranscriptWindow(start: 3_800, end: 5_000))
        #expect(prepared?.preparedHistory(
            afterArrival: true, maximumRows: TranscriptWindow.livePreparedLimit
        ) == nil)
    }

    /// The shape of a long session run through subagents: their rows are absorbed into the call
    /// that started them and most system rows draw nothing, so its last 1,200 rows drew 1,057
    /// points under a 1,100 point pane, and the conversation above them could not be reached.
    private static let subagentSessionRows = 3_615
    private static let subagentPointsPerRow = 1_057.0 / Double(TranscriptWindow.livePreparedLimit)
    private static let pane = 1_100.0

    private static func preparedAtLiveEnd(rowCount: Int, pointsPerRow: Double) -> TranscriptWindow {
        var window = TranscriptWindow.liveEnd(rowCount: rowCount)
        while let next = window.preparedHistory(
            afterArrival: true,
            maximumRows: TranscriptWindow.preparationLimit(
                atLiveEnd: true, drawnHeight: Double(window.count) * pointsPerRow, paneHeight: pane
            )
        ) {
            window = next
        }
        return window
    }

    @Test("live-end preparation goes past its row budget while the rows draw less than a few panes")
    func livePreparationFillsThePane() {
        let window = Self.preparedAtLiveEnd(
            rowCount: Self.subagentSessionRows, pointsPerRow: Self.subagentPointsPerRow
        )
        #expect(window.start == 0)
    }

    @Test("live-end preparation keeps its row budget once the rows fill a few panes")
    func livePreparationKeepsItsBudgetForTallRows() {
        let window = Self.preparedAtLiveEnd(rowCount: 5_000, pointsPerRow: 40)
        #expect(window == TranscriptWindow(start: 3_800, end: 5_000))
    }

    @Test("the live end keeps history that draws less than a few panes")
    func liveTrimKeepsShortHistory() {
        let whole = TranscriptWindow(start: 0, end: Self.subagentSessionRows)
        let drawn = Double(Self.subagentSessionRows) * Self.subagentPointsPerRow
        #expect(whole.trimmedAtLiveEnd(drawnHeight: drawn, paneHeight: Self.pane) == nil)
    }

    @Test("the live end drops old rows that still leave a few panes drawn")
    func liveTrimDropsTallHistory() {
        let trimmed = TranscriptWindow(start: 200, end: 5_000)
            .trimmedAtLiveEnd(drawnHeight: 4_800 * 40, paneHeight: Self.pane)
        #expect(trimmed == TranscriptWindow(start: 3_800, end: 5_000))
    }

    @Test("returning to the live end discards only old drawn entries")
    func liveWindowCanDropOldEntries() {
        let window = TranscriptWindow(start: 200, end: 5_000)
        #expect(window.keepingLatest(TranscriptWindow.livePreparedLimit)
            == TranscriptWindow(start: 3_800, end: 5_000))
        #expect(TranscriptWindow(start: 4_000, end: 5_000).keepingLatest(1_200)
            == TranscriptWindow(start: 4_000, end: 5_000))
    }

    @Test("idle preparation stops once the table knows the whole history")
    func idlePreparationStopsAtTheTop() {
        let whole = TranscriptWindow(start: 0, end: 2_000)
        #expect(whole.preparedHistory(afterArrival: true) == nil)
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
