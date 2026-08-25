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
        offset: Double = 1_200,
        isAtLiveEnd: Bool = false,
        rowCount: Int = 400,
        drawn: TranscriptWindow = TranscriptWindow(start: 0, end: 400)
    ) -> TranscriptPaneState {
        TranscriptPaneState(
            expanded: expanded,
            offset: offset,
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

    /// The three tests that used to sit at the foot of this suite are gone with the rule they
    /// held down: a restore is no longer refused because the pane is a different width or the text
    /// a different size. See `TranscriptResume.placement`, which carries the reversal and the
    /// reason for it.

    @Test("a pane that has never held this session opens the way it always did")
    func nothingRemembered() {
        let placement = TranscriptResume.placement(
            for: nil, rowCount: 400
        )
        #expect(placement == .first)
    }

    @Test("a session with no rows opens the way it always did")
    func emptySession() {
        #expect(TranscriptResume.placement(for: state(), rowCount: 0) == .first)
    }

    @Test("a reader who left at the end is put back at the end, not at the offset")
    func liveEndOutranksTheOffset() {
        let placement = TranscriptResume.placement(
            for: state(offset: 9_000, isAtLiveEnd: true), rowCount: 400
        )
        #expect(placement == .liveEnd)
    }

    /// The case the flag exists for: a turn ran while the pane was on another tab, so the content
    /// grew and the number of points that meant the end names the middle now.
    @Test("the end still means the end after the session has grown")
    func liveEndAfterGrowth() {
        let placement = TranscriptResume.placement(
            for: state(offset: 9_000, isAtLiveEnd: true, rowCount: 400),
            rowCount: 6_000
        )
        #expect(placement == .liveEnd)
    }

    @Test("a reader who left part way up is put back there")
    func offsetIsRestored() {
        let placement = TranscriptResume.placement(
            for: state(offset: 1_200), rowCount: 400
        )
        #expect(placement == .offset(1_200))
    }

    @Test("a session that has grown under a scrolled reader keeps their offset")
    func growthDoesNotMoveAReader() {
        let placement = TranscriptResume.placement(
            for: state(offset: 1_200, rowCount: 400), rowCount: 900
        )
        #expect(placement == .offset(1_200))
    }

    /// Rows are appended and never removed while a pane is away, so fewer of them means the
    /// session was read again from the start and nothing measured against the old one carries.
    @Test("a session with fewer rows than it had is not the one that offset was measured in")
    func shrunkSessionIsNotResumed() {
        let placement = TranscriptResume.placement(
            for: state(rowCount: 400), rowCount: 12
        )
        #expect(placement == .first)
    }

    @Test("the top of the content is a first open rather than a restored nought")
    func topIsNotRestored() {
        let placement = TranscriptResume.placement(
            for: state(offset: 0), rowCount: 400
        )
        #expect(placement == .first)
    }
}
