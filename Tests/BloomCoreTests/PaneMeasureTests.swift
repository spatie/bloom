import Foundation
import Testing
@testable import BloomCore

/// The point of rounding a pane measurement is that a drag stops writing state once a frame, so
/// what is asserted is the step and the direction each side errs in, never a particular height.
@Suite("Rounding a measured pane")
struct PaneMeasureTests {
    @Test("a pane not laid out yet stays nought, which reads as no cap")
    func unmeasuredIsNought() {
        #expect(PaneMeasure.room(0) == 0)
        #expect(PaneMeasure.room(-40) == 0)
        #expect(PaneMeasure.chrome(0) == 0)
        #expect(PaneMeasure.chrome(-40) == 0)
    }

    /// Above one step, which is the only place the rounding has a choice to make. Below it the
    /// floor below wins, deliberately.
    @Test("room is rounded down and never overstates the space measured")
    func roomRoundsDown() {
        for step in Int(PaneMeasure.step)...400 {
            let height = CGFloat(step)
            #expect(PaneMeasure.room(height) <= height)
        }
        #expect(PaneMeasure.room(800) == 800)
        #expect(PaneMeasure.room(807) == 800)
    }

    @Test("a pane dragged to a sliver keeps one step, because nought means unmeasured")
    func slimPaneKeepsOneStep() {
        #expect(PaneMeasure.room(1) == PaneMeasure.step)
        #expect(PaneMeasure.room(PaneMeasure.step - 0.5) == PaneMeasure.step)
    }

    @Test("chrome is rounded up, because it is taken off the room")
    func chromeRoundsUp() {
        for step in 1...400 {
            let height = CGFloat(step)
            #expect(PaneMeasure.chrome(height) >= height)
        }
        #expect(PaneMeasure.chrome(80) == 80)
        #expect(PaneMeasure.chrome(73) == 80)
    }

    /// The whole reason either function exists: a drag that crosses a pixel must not change the
    /// answer, and one that crosses a step must.
    @Test("a drag inside one step changes nothing")
    func aDragInsideOneStepChangesNothing() {
        let start = PaneMeasure.room(600)
        for pixel in 0..<Int(PaneMeasure.step) {
            #expect(PaneMeasure.room(600 + CGFloat(pixel)) == start)
        }
        #expect(PaneMeasure.room(600 + PaneMeasure.step) != start)
    }
}
