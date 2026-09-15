import Testing
import Foundation
@testable import BloomCore

@Suite("Holding a transcript back, and letting go of it")
struct TranscriptPaneHoldTests {
    // MARK: - Arriving at another conversation

    /// The pane is blank while this runs, so it is a backstop rather than a length anybody
    /// watches: a load that never returns, a task cancelled on its way, a session with nothing in
    /// it. It still has to be short enough that such a pane is not blank for a noticeable time.
    @Test("a pane pointed at a conversation does not wait for ever")
    func revealsAnArrivalAnyway() {
        #expect(TranscriptPaneHold.arrival > .zero)
        #expect(TranscriptPaneHold.arrival <= .seconds(2))
    }

    // MARK: - Reflowing while a pane is dragged

    @Test("a slow drag waits for the width to move a step before reflowing")
    func slowDragWaitsForAStep() {
        #expect(!TranscriptPaneHold.reflowsNow(from: 800, to: 801))
        #expect(!TranscriptPaneHold.reflowsNow(from: 800, to: 800 - TranscriptPaneHold.reflowStep + 1))
    }

    @Test("a step either way reflows on the frame")
    func aStepReflows() {
        #expect(TranscriptPaneHold.reflowsNow(from: 800, to: 800 + TranscriptPaneHold.reflowStep))
        #expect(TranscriptPaneHold.reflowsNow(from: 800, to: 800 - TranscriptPaneHold.reflowStep))
        #expect(TranscriptPaneHold.reflowsNow(from: 800, to: 640))
    }

    /// The settle is what finishes a step the drag skipped, so it has to come quickly enough
    /// that a paragraph drawn into the row under it is not something the reader sits and looks at.
    @Test("the width settles quickly once the hand stops")
    func settlesQuickly() {
        #expect(TranscriptPaneHold.settle > .zero)
        #expect(TranscriptPaneHold.settle <= .milliseconds(300))
    }

    // MARK: - What a reflow measures once it settles

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
    /// every one of those would stall the pane.
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
