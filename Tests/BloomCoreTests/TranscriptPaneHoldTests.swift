import Testing
import Foundation
@testable import BloomCore

@Suite("Holding a transcript back, and letting go of it")
struct TranscriptPaneHoldTests {
    // MARK: - Whether a change is held at all

    @Test("a pane that changes width is held")
    func holdsARealChange() {
        #expect(TranscriptPaneHold.holds(from: 800, to: 640))
        #expect(TranscriptPaneHold.holds(from: 640, to: 800))
    }

    /// The same half point `TranscriptRowHeights` calls the same width, asked of the same answer:
    /// a change that cannot rewrap a paragraph is not worth a fade.
    @Test("a fraction of a point is not a resize")
    func ignoresAFraction() {
        #expect(!TranscriptPaneHold.holds(from: 831.5, to: 831.75))
        #expect(!TranscriptPaneHold.holds(from: 800, to: 800))
    }

    /// **The offscreen capture path, and every pane's first layout.** A pane arriving at its first
    /// real width has nothing drawn to hold, and freezing there would photograph an empty
    /// transcript.
    @Test("a pane arriving at its first width is not held")
    func doesNotHoldTheFirstLayout() {
        #expect(!TranscriptPaneHold.holds(from: 0, to: 900))
        #expect(!TranscriptPaneHold.holds(from: 1, to: 900))
        #expect(!TranscriptPaneHold.holds(from: 900, to: 0))
    }

    // MARK: - Letting go

    /// Every hold is armed with one of these, so no gesture whose end event goes missing can leave
    /// a frozen picture on screen.
    @Test("a hold with no hand on it lets go quickly")
    func letsGoOnItsOwn() {
        #expect(
            TranscriptPaneHold.letsGo(of: .whatIsDrawn, underAHand: false)
                == TranscriptPaneHold.quiet
        )
        #expect(TranscriptPaneHold.quiet < .seconds(1))
    }

    @Test("a hold under a hand waits longer, and still ends")
    func waitsForAHand() {
        let held = TranscriptPaneHold.letsGo(of: .whatIsDrawn, underAHand: true)
        #expect(held == TranscriptPaneHold.quietUnderAHand)
        #expect(held > TranscriptPaneHold.quiet)
        #expect(held < .seconds(30))
    }

    /// A pane waiting for a conversation is waiting for a read and one screen of measuring, not
    /// for a hand, so the hand makes no difference to it.
    @Test("a pane holding nothing waits for its conversation and no longer")
    func waitsForAnArrival() {
        #expect(
            TranscriptPaneHold.letsGo(of: .nothing, underAHand: true) == TranscriptPaneHold.arrival
        )
        #expect(
            TranscriptPaneHold.letsGo(of: .nothing, underAHand: false) == TranscriptPaneHold.arrival
        )
    }

    // MARK: - Arriving at another conversation

    /// The pane is blank while this runs, so it is a backstop rather than a length anybody
    /// watches: a load that never returns, a task cancelled on its way, a session with nothing in
    /// it. It still has to be short enough that such a pane is not blank for a noticeable time.
    @Test("a pane pointed at a conversation does not wait for ever")
    func revealsAnArrivalAnyway() {
        #expect(TranscriptPaneHold.arrival > TranscriptPaneHold.quiet)
        #expect(TranscriptPaneHold.arrival <= .seconds(2))
    }

    // MARK: - What is measured before the fade

    @Test("what the reader can see is measured, and a screen either side of it")
    func measuresAroundTheReader() {
        let rows = TranscriptPaneHold.eager(visible: 400..<420, count: 1_855)
        #expect(rows == 380..<440)
    }

    @Test("the margin stops at the ends of the conversation")
    func clampsToTheList() {
        #expect(TranscriptPaneHold.eager(visible: 0..<10, count: 40) == 0..<20)
        #expect(TranscriptPaneHold.eager(visible: 30..<40, count: 40) == 20..<40)
    }

    /// A conversation of empty rows can have thousands of them on screen at once, and measuring
    /// every one of those is the stall the hold exists to remove.
    @Test("the margin is capped, and never at the cost of what is visible")
    func capsTheMargin() {
        let rows = TranscriptPaneHold.eager(visible: 500..<1_000, count: 2_000)
        #expect(rows.lowerBound == 500 - TranscriptPaneHold.margin)
        #expect(rows.upperBound == 1_000 + TranscriptPaneHold.margin)
        #expect(rows.contains(500))
        #expect(rows.contains(999))
    }

    @Test("a pane with nothing on screen measures nothing")
    func measuresNothingForAnEmptyPane() {
        #expect(TranscriptPaneHold.eager(visible: 0..<0, count: 1_855).isEmpty)
        #expect(TranscriptPaneHold.eager(visible: 0..<10, count: 0).isEmpty)
    }
}
