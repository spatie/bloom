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
    private func measure(width: Double = 900, fontScale: Double = 1) -> TranscriptPaneState.Measure {
        TranscriptPaneState.Measure(width: width, fontScale: fontScale)
    }

    private func state(
        expanded: Set<Int> = [],
        offset: Double = 1_200,
        isAtLiveEnd: Bool = false,
        rowCount: Int = 400,
        measure: TranscriptPaneState.Measure? = nil
    ) -> TranscriptPaneState {
        TranscriptPaneState(
            expanded: expanded,
            offset: offset,
            isAtLiveEnd: isAtLiveEnd,
            rowCount: rowCount,
            measure: measure ?? self.measure()
        )
    }

    // MARK: What the arrival frame draws

    @Test("a pane that has never held this session draws the tail")
    func nothingRememberedDrawsTheTail() {
        #expect(TranscriptResume.drawsInFull(nil) == false)
    }

    /// An offset is a point down a laid out document, and the only way to resolve one is to lay out
    /// everything above it.
    @Test("a pane coming back to a place in the middle draws the whole session")
    func aReturnToAnOffsetDrawsInFull() {
        #expect(TranscriptResume.drawsInFull(state(isAtLiveEnd: false)))
        #expect(TranscriptResume.opensOnTheTail(state(isAtLiveEnd: false)) == false)
    }

    /// The case the whole change is about, and the common one: nothing above the viewport has to
    /// exist for the end of the session to be the end of the session, so the rows above it are a
    /// layout nobody has asked for. Measured with `--tab-probe` at 114ms to 218ms of stopped main
    /// thread per return.
    @Test("a pane coming back to the live end draws only the tail, and owes the history")
    func aReturnToTheLiveEndDrawsTheTail() {
        #expect(TranscriptResume.drawsInFull(state(isAtLiveEnd: true)) == false)
        #expect(TranscriptResume.opensOnTheTail(state(isAtLiveEnd: true)))
    }

    /// A first open draws a tail too, and the difference is what it owes afterwards: its history
    /// goes back on the timer that has always put it there, because an unread mark or a searched
    /// row can be anywhere in the session and a reader arriving has to be able to reach them.
    @Test("a first open owes its history to the clock rather than to the reader")
    func aFirstOpenDoesNotOpenOnTheTail() {
        #expect(TranscriptResume.opensOnTheTail(nil) == false)
    }

    // MARK: Where it opens

    @Test("a pane that has never held this session opens the way it always did")
    func nothingRemembered() {
        let placement = TranscriptResume.placement(
            for: nil, rowCount: 400, measure: measure()
        )
        #expect(placement == .first)
    }

    @Test("a session with no rows opens the way it always did")
    func emptySession() {
        #expect(TranscriptResume.placement(for: state(), rowCount: 0, measure: measure()) == .first)
    }

    @Test("a reader who left at the end is put back at the end, not at the offset")
    func liveEndOutranksTheOffset() {
        let placement = TranscriptResume.placement(
            for: state(offset: 9_000, isAtLiveEnd: true), rowCount: 400, measure: measure()
        )
        #expect(placement == .liveEnd)
    }

    /// The case the flag exists for: a turn ran while the pane was on another tab, so the content
    /// grew and the number of points that meant the end names the middle now.
    @Test("the end still means the end after the session has grown")
    func liveEndAfterGrowth() {
        let placement = TranscriptResume.placement(
            for: state(offset: 9_000, isAtLiveEnd: true, rowCount: 400),
            rowCount: 6_000, measure: measure()
        )
        #expect(placement == .liveEnd)
    }

    @Test("a reader who left part way up is put back there")
    func offsetIsRestored() {
        let placement = TranscriptResume.placement(
            for: state(offset: 1_200), rowCount: 400, measure: measure()
        )
        #expect(placement == .offset(1_200))
    }

    @Test("a session that has grown under a scrolled reader keeps their offset")
    func growthDoesNotMoveAReader() {
        let placement = TranscriptResume.placement(
            for: state(offset: 1_200, rowCount: 400), rowCount: 900, measure: measure()
        )
        #expect(placement == .offset(1_200))
    }

    /// Rows are appended and never removed while a pane is away, so fewer of them means the
    /// session was read again from the start and nothing measured against the old one carries.
    @Test("a session with fewer rows than it had is not the one that offset was measured in")
    func shrunkSessionIsNotResumed() {
        let placement = TranscriptResume.placement(
            for: state(rowCount: 400), rowCount: 12, measure: measure()
        )
        #expect(placement == .first)
    }

    @Test("an offset measured at another width is a point into another document")
    func widthChangeStalesTheOffset() {
        let placement = TranscriptResume.placement(
            for: state(measure: measure(width: 900)), rowCount: 400, measure: measure(width: 640)
        )
        #expect(placement == .first)
    }

    @Test("and so is one measured at another text size")
    func fontScaleChangeStalesTheOffset() {
        let placement = TranscriptResume.placement(
            for: state(measure: measure(fontScale: 1)),
            rowCount: 400, measure: measure(fontScale: 1.2)
        )
        #expect(placement == .first)
    }

    /// A width change moves nobody who was at the end, because the end is a place rather than a
    /// measurement.
    @Test("a width change does not throw away the live end")
    func widthChangeKeepsTheLiveEnd() {
        let placement = TranscriptResume.placement(
            for: state(isAtLiveEnd: true, measure: measure(width: 900)),
            rowCount: 400, measure: measure(width: 640)
        )
        #expect(placement == .liveEnd)
    }

    /// The frame the geometry has not landed on yet, which is most arrival frames. A measurement
    /// nobody has taken must not be allowed to contradict one that was.
    @Test("a pane that has not been measured yet keeps the offset it was given")
    func unmeasuredPaneKeepsTheOffset() {
        let placement = TranscriptResume.placement(
            for: state(offset: 1_200, measure: measure(width: 900)), rowCount: 400, measure: nil
        )
        #expect(placement == .offset(1_200))
    }

    @Test("and so does one whose last visit was never measured")
    func unmeasuredMemoryKeepsTheOffset() {
        let unmeasured = TranscriptPaneState(
            expanded: [], offset: 1_200, isAtLiveEnd: false, rowCount: 400, measure: nil
        )
        let placement = TranscriptResume.placement(
            for: unmeasured, rowCount: 400, measure: measure(width: 640)
        )
        #expect(placement == .offset(1_200))
    }

    @Test("the top of the content is a first open rather than a restored nought")
    func topIsNotRestored() {
        let placement = TranscriptResume.placement(
            for: state(offset: 0), rowCount: 400, measure: measure()
        )
        #expect(placement == .first)
    }
}
