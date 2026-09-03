import Testing
import Foundation
@testable import BloomCore

@Suite("How much air a line of transcript text gets")
struct TextLeadingTests {
    /// The five steps of `ChatTextSize` resolved against the body rung on macOS 26: the point size
    /// San Francisco comes out at, and the line box `NSLayoutManager` lays it out in. Measured
    /// rather than derived, because the rounding to a whole point happens twice on the way here
    /// and nothing in the core can ask AppKit for the answer.
    private static let bodySteps: [(size: Double, box: Double)] = [
        (12, 15), (13, 16), (15, 18), (17, 20), (20, 23),
    ]

    // MARK: - Prose, as a ratio of the size it is set at

    @Test("the line height lands on the ratio at every chat text size")
    func holdsTheRatioAcrossTheRange() {
        for step in Self.bodySteps {
            let extra = TextLeading.overPointSize(lineHeight: step.box, pointSize: step.size)
            let ratio = (step.box + extra) / step.size
            #expect(abs(ratio - TextLeading.proseRatio) < 0.05)
        }
    }

    @Test("the default chat size gets six points where it used to get three")
    func theDefaultMoves() {
        #expect(TextLeading.overPointSize(lineHeight: 16, pointSize: 13) == 6)
    }

    @Test("a fixed three points is what the ratio is not")
    func aConstantDriftsAndThisDoesNot() {
        // The bug this replaces: the same three points read as 1.46 at the default and 1.30 at
        // the largest step, so asking for larger text tightened the paragraph.
        let smallest = (15.0 + 3) / 12
        let largest = (23.0 + 3) / 20
        #expect(smallest - largest > 0.15)

        let ledSmallest = (15.0 + TextLeading.overPointSize(lineHeight: 15, pointSize: 12)) / 12
        let ledLargest = (23.0 + TextLeading.overPointSize(lineHeight: 23, pointSize: 20)) / 20
        #expect(abs(ledSmallest - ledLargest) < 0.05)
    }

    @Test("the answer is a whole number of points")
    func roundsToAPoint() {
        for step in Self.bodySteps {
            let extra = TextLeading.overPointSize(lineHeight: step.box, pointSize: step.size)
            #expect(extra == extra.rounded())
        }
    }

    @Test("a line box already past the ratio is left alone rather than crushed")
    func neverNegative() {
        #expect(TextLeading.overPointSize(lineHeight: 40, pointSize: 13) == 0)
    }

    @Test("nothing is added to a font that has no size")
    func refusesNonsense() {
        #expect(TextLeading.overPointSize(lineHeight: 0, pointSize: 13) == 0)
        #expect(TextLeading.overPointSize(lineHeight: 16, pointSize: 0) == 0)
    }

    // MARK: - Code, as a ratio of its own line box

    @Test("the permission panel's command is unchanged at the default chat size")
    func codeHoldsItsFourPoints() {
        // Eleven point mono in a thirteen point line box, which is where the four points
        // `Metrics.spacingSmall` used to supply came from.
        #expect(TextLeading.overLineBox(lineHeight: 13) == 4)
    }

    @Test("a command set larger keeps the ratio it was decided at")
    func codeHoldsItsRatio() {
        // The same five steps, at the monospaced rung the panel actually uses.
        for box in [12.0, 13, 16, 17, 20] {
            let ratio = (box + TextLeading.overLineBox(lineHeight: box)) / box
            #expect(abs(ratio - TextLeading.codeRatio) < 0.05)
        }
    }

    @Test("code is measured against its box and prose against its size, and they do not agree")
    func theTwoDenominatorsAreNotOneDecision() {
        // A guard against somebody folding the two ratios together later: at the same eleven
        // point rung the two rules answer differently, and that is the point of there being two.
        let prose = TextLeading.overPointSize(lineHeight: 13, pointSize: 11)
        let code = TextLeading.overLineBox(lineHeight: 13)
        #expect(prose != code)
    }
}
