import Testing
import Foundation
@testable import BloomCore

/// How much of a running setup log the transcript gives up to it, which is a share of the pane
/// rather than a number of lines.
@Suite("Setup tail window")
struct SetupTailWindowTests {
    /// The height AppKit lays a line of the monospaced callout face out on at the default text
    /// size, which is what the view hands in.
    private let lineHeight = 17.0

    @Test("the window is half the pane, whatever the pane is")
    func scalesWithThePane() {
        // The smallest window Bloom opens leaves the transcript about this tall.
        #expect(SetupTailWindow.cap(paneHeight: 420, lineHeight: lineHeight) == 12)
        // And a large one gives about twice that, which is the point of the change.
        #expect(SetupTailWindow.cap(paneHeight: 850, lineHeight: lineHeight) == 25)
    }

    @Test("a squeezed pane still shows something moving")
    func holdsTheFloor() {
        // The terminal split dragged nearly to the top.
        #expect(SetupTailWindow.cap(paneHeight: 60, lineHeight: lineHeight) == SetupTailWindow.minimumCap)
    }

    @Test("a tall display does not hand over forty lines")
    func holdsTheCeiling() {
        #expect(SetupTailWindow.cap(paneHeight: 2000, lineHeight: lineHeight) == SetupTailWindow.maximumCap)
    }

    @Test("a pane that has not been laid out answers with the height the row already had")
    func survivesAnUnmeasuredPane() {
        // Not the floor. A window opens, and a tab that is not on screen sits, at zero height, and
        // three lines on that frame followed by twenty five on the next is a jump on every open.
        #expect(SetupTailWindow.cap(paneHeight: 0, lineHeight: lineHeight) == SetupTailWindow.settled)
        #expect(SetupTailWindow.cap(paneHeight: 850, lineHeight: 0) == SetupTailWindow.settled)
    }

    @Test("the first five lines are drawn at the height five lines take")
    func doesNotGrowThroughTheFirstSeconds() {
        // The mover `a98e055` measured and killed: a block that grew a line at a time while the
        // script printed its first lines. Nought through five are all one height.
        for printed in 0...5 {
            #expect(SetupTailWindow.lines(cap: 25, logLines: printed) == 5)
        }
    }

    @Test("above that the block is the size of what is in it")
    func fillsToTheLog() {
        // So a quiet script does not leave four hundred points of empty ruled box over the
        // conversation for as long as it takes to finish.
        #expect(SetupTailWindow.lines(cap: 25, logLines: 9) == 9)
        #expect(SetupTailWindow.lines(cap: 25, logLines: 24) == 24)
    }

    @Test("and stops for good at the cap")
    func stopsAtTheCap() {
        #expect(SetupTailWindow.lines(cap: 25, logLines: 25) == 25)
        #expect(SetupTailWindow.lines(cap: 25, logLines: 4000) == 25)
    }

    @Test("a pane too short for five lines is not given five")
    func neverExceedsACapBelowTheSettledHeight() {
        // Otherwise the floor would put back the thing the cap exists to prevent, which is a block
        // taller than the pane it is drawn in.
        #expect(SetupTailWindow.lines(cap: 3, logLines: 0) == 3)
        #expect(SetupTailWindow.lines(cap: 3, logLines: 40) == 3)
    }

    @Test("a failure is never shorter than a success in the same pane")
    func readsAFailureAtLength() {
        #expect(SetupTailWindow.failureLines(cap: 3) == SetupTailWindow.failureFloor)
        #expect(SetupTailWindow.failureLines(cap: 25) == 25)
        for paneHeight in stride(from: 0.0, through: 2000.0, by: 25.0) {
            let cap = SetupTailWindow.cap(paneHeight: paneHeight, lineHeight: lineHeight)
            #expect(SetupTailWindow.failureLines(cap: cap) >= SetupTailWindow.lines(cap: cap, logLines: 4000))
        }
    }
}
