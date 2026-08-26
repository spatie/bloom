import Testing
import Foundation
@testable import BloomCore

@Suite("Holding the transcript still while a pane is resized")
struct TranscriptResizeHoldTests {
    // MARK: - Whether a change is held at all

    @Test("a pane that changes width is held")
    func holdsARealChange() {
        #expect(TranscriptResizeHold.holds(from: 800, to: 640))
        #expect(TranscriptResizeHold.holds(from: 640, to: 800))
    }

    /// The same half point `TranscriptRowHeights` calls the same width, asked of the same answer:
    /// a change that cannot rewrap a paragraph is not worth a fade.
    @Test("a fraction of a point is not a resize")
    func ignoresAFraction() {
        #expect(!TranscriptResizeHold.holds(from: 831.5, to: 831.75))
        #expect(!TranscriptResizeHold.holds(from: 800, to: 800))
    }

    /// **The offscreen capture path, and every pane's first layout.** A pane arriving at its first
    /// real width has nothing drawn to hold, and freezing there would photograph an empty
    /// transcript.
    @Test("a pane arriving at its first width is not held")
    func doesNotHoldTheFirstLayout() {
        #expect(!TranscriptResizeHold.holds(from: 0, to: 900))
        #expect(!TranscriptResizeHold.holds(from: 1, to: 900))
        #expect(!TranscriptResizeHold.holds(from: 900, to: 0))
    }

    // MARK: - Letting go

    /// Every hold is armed with one of these, so no gesture whose end event goes missing can leave
    /// a frozen picture on screen.
    @Test("a hold with no hand on it lets go quickly")
    func letsGoOnItsOwn() {
        #expect(TranscriptResizeHold.letsGo(underAHand: false) == TranscriptResizeHold.quiet)
        #expect(TranscriptResizeHold.quiet < .seconds(1))
    }

    @Test("a hold under a hand waits longer, and still ends")
    func waitsForAHand() {
        let held = TranscriptResizeHold.letsGo(underAHand: true)
        #expect(held == TranscriptResizeHold.quietUnderAHand)
        #expect(held > TranscriptResizeHold.quiet)
        #expect(held < .seconds(30))
    }

    // MARK: - What is measured before the fade

    @Test("what the reader can see is measured, and a screen either side of it")
    func measuresAroundTheReader() {
        let rows = TranscriptResizeHold.eager(visible: 400..<420, count: 1_855)
        #expect(rows == 380..<440)
    }

    @Test("the margin stops at the ends of the conversation")
    func clampsToTheList() {
        #expect(TranscriptResizeHold.eager(visible: 0..<10, count: 40) == 0..<20)
        #expect(TranscriptResizeHold.eager(visible: 30..<40, count: 40) == 20..<40)
    }

    /// A conversation of empty rows can have thousands of them on screen at once, and measuring
    /// every one of those is the stall the hold exists to remove.
    @Test("the margin is capped, and never at the cost of what is visible")
    func capsTheMargin() {
        let rows = TranscriptResizeHold.eager(visible: 500..<1_000, count: 2_000)
        #expect(rows.lowerBound == 500 - TranscriptResizeHold.margin)
        #expect(rows.upperBound == 1_000 + TranscriptResizeHold.margin)
        #expect(rows.contains(500))
        #expect(rows.contains(999))
    }

    @Test("a pane with nothing on screen measures nothing")
    func measuresNothingForAnEmptyPane() {
        #expect(TranscriptResizeHold.eager(visible: 0..<0, count: 1_855).isEmpty)
        #expect(TranscriptResizeHold.eager(visible: 0..<10, count: 0).isEmpty)
    }
}
