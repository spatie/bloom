import Foundation
import Testing
@testable import BloomCore

/// What a chat pane does with what it wrote down when it last left a conversation.
///
/// The decision is here rather than in `TranscriptListView` for the reason the split exists: the
/// view is destroyed by every tab switch, which is the very thing being fixed, and a rule taken
/// inside one is a rule nothing can hold still.
@Suite("Transcript resume")
struct TranscriptResumeTests {
    private func state(
        expanded: Set<Int> = [],
        anchorSeq: Int? = 120,
        isAtLiveEnd: Bool = false,
        rowCount: Int = 400,
        drawn: TranscriptWindow = TranscriptWindow(start: 0, end: 400)
    ) -> TranscriptPaneState {
        TranscriptPaneState(
            expanded: expanded,
            anchorSeq: anchorSeq,
            isAtLiveEnd: isAtLiveEnd,
            rowCount: rowCount,
            drawn: drawn
        )
    }

    // MARK: What the arrival frame draws

    @Test("a pane that has never held this session draws the tail")
    func nothingRememberedDrawsTheTail() {
        let window = TranscriptResume.window(nil, tailStart: 3_920, rowCount: 4_000)
        #expect(window == TranscriptWindow(start: 3_920, end: 4_000))
    }

    @Test("a pane coming back to a session goes back to the window it was reading in")
    func aReturnGoesBackToItsWindow() {
        let remembered = state(drawn: TranscriptWindow(start: 3_600, end: 4_000))
        let window = TranscriptResume.window(remembered, tailStart: 3_920, rowCount: 4_000)
        #expect(window == TranscriptWindow(start: 3_600, end: 4_000))
    }

    @Test("a pane with nothing written down is arriving, and one with a memory is coming back")
    func resumingIsHavingBeenHereBefore() {
        #expect(TranscriptResume.isResuming(nil) == false)
        #expect(TranscriptResume.isResuming(state()))
    }

    @Test("a window with nothing in it is not restored, because it would draw a blank transcript")
    func anEmptyWindowIsNotAWindow() {
        let remembered = state(drawn: TranscriptWindow(start: 0, end: 0))
        let window = TranscriptResume.window(remembered, tailStart: 3_920, rowCount: 4_000)
        #expect(window == TranscriptWindow(start: 3_920, end: 4_000))
    }

    @Test("a window from a session that has since been read again is clamped to it")
    func aStaleWindowIsClamped() {
        let remembered = state(drawn: TranscriptWindow(start: 9_000, end: 9_400))
        let window = TranscriptResume.window(remembered, tailStart: 20, rowCount: 100)
        #expect(window == TranscriptWindow(start: 100, end: 100))
    }

    // MARK: Where it opens

    @Test("a pane that has never held this session opens the way it always did")
    func nothingRemembered() {
        #expect(TranscriptResume.placement(for: nil, rowCount: 400) == .first)
    }

    @Test("a session with no rows opens the way it always did")
    func emptySession() {
        #expect(TranscriptResume.placement(for: state(), rowCount: 0) == .first)
    }

    @Test("a reader who left at the end is put back at the end, not at the row that was there")
    func liveEndOutranksTheAnchor() {
        let placement = TranscriptResume.placement(
            for: state(anchorSeq: 120, isAtLiveEnd: true), rowCount: 400
        )
        #expect(placement == .liveEnd)
    }

    /// The case the flag exists for, and the one the owner reported: a turn ran while the pane was
    /// on another workspace, so the end has moved and the row that used to be at the top of the
    /// pane is not where anybody wants to be put back.
    @Test("the end still means the end after the session has grown")
    func liveEndAfterGrowth() {
        let placement = TranscriptResume.placement(
            for: state(anchorSeq: 120, isAtLiveEnd: true, rowCount: 400), rowCount: 6_000
        )
        #expect(placement == .liveEnd)
    }

    @Test("a reader who left part way up is put back at the row they were reading")
    func theAnchorRowIsRestored() {
        #expect(TranscriptResume.placement(for: state(anchorSeq: 120), rowCount: 400) == .row(120))
    }

    @Test("a session that has grown under a scrolled reader keeps their row")
    func growthDoesNotMoveAReader() {
        let placement = TranscriptResume.placement(
            for: state(anchorSeq: 120, rowCount: 400), rowCount: 900
        )
        #expect(placement == .row(120))
    }

    /// The whole reason the place is a row. A width change, a text size change and the lazy stack
    /// replacing its guessed heights with measured ones all move every point in the document and
    /// none of them move a row. The three refusals this suite used to hold are gone with the
    /// offset they existed to protect.
    @Test("nothing about how the pane is drawn can stale a row")
    func aRowSurvivesEveryMeasurement() {
        #expect(TranscriptResume.placement(for: state(anchorSeq: 7), rowCount: 400) == .row(7))
    }

    /// Rows are appended and never removed while a pane is away, so fewer of them means the
    /// session was read again from the start and nothing written about the old one carries.
    @Test("a session with fewer rows than it had is not the one that anchor was taken in")
    func shrunkSessionIsNotResumed() {
        let placement = TranscriptResume.placement(for: state(rowCount: 400), rowCount: 12)
        #expect(placement == .first)
    }

    @Test("a pane that never saw a row at its top opens the way a fresh visit does")
    func noAnchorOpensFresh() {
        #expect(TranscriptResume.placement(for: state(anchorSeq: nil), rowCount: 400) == .first)
    }
}
