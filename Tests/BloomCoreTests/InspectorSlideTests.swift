import Testing
@testable import BloomCore

/// The title bar's trailing end on its way between two widths.
///
/// The reason every one of these is worth pinning is that the number this produces is compared,
/// frame by frame, against two animations it cannot see: the split view's pane and the band's own
/// SwiftUI slide. A curve that is nearly `easeInEaseOut` reads as a seam opening and closing in the
/// middle of the movement.
@Suite struct InspectorSlideTests {
    private let slide = InspectorSlide(from: 1, to: 381, seconds: 0.25)

    @Test func itStartsWhereItWasAndEndsWhereItIsGoing() {
        #expect(slide.width(after: 0) == 1)
        #expect(slide.width(after: -1) == 1)
        #expect(slide.width(after: 0.25) == 381)
        #expect(slide.width(after: 10) == 381)
    }

    @Test func halfwayThroughTheTimeIsHalfwayThroughTheDistance() {
        // The curve is symmetric, so this is the one point on it that needs no reference value.
        #expect(abs(slide.width(after: 0.125) - 191) < 0.01)
    }

    @Test func itOnlyEverMovesForwards() {
        var last = slide.width(after: 0)
        for step in 1...250 {
            let width = slide.width(after: Double(step) / 1000)
            #expect(width >= last)
            last = width
        }
        #expect(last == 381)
    }

    @Test func aSlideThatIsGoingBackwardsIsTheSameCurveTheOtherWay() {
        let out = InspectorSlide(from: 381, to: 1, seconds: 0.25)
        #expect(out.width(after: 0) == 381)
        #expect(abs(out.width(after: 0.125) - 191) < 0.01)
        #expect(out.width(after: 0.25) == 1)
    }

    @Test func theCurveIsTheCubicBothFrameworksSpell() {
        // Computed from the bezier through (0.42, 0) and (0.58, 1), which is what
        // `kCAMediaTimingFunctionEaseInEaseOut` and SwiftUI's `.easeInOut` both are.
        let expected: [(Double, Double)] = [
            (0.1, 0.019722), (0.25, 0.129162), (0.4, 0.331884), (0.5, 0.5),
            (0.6, 0.668116), (0.75, 0.870838), (0.9, 0.980278),
        ]
        for (fraction, value) in expected {
            #expect(abs(InspectorSlide.ease(fraction) - value) < 0.001)
        }
    }

    @Test func theCurveIsSymmetricAboutTheMiddle() {
        for step in 0...100 {
            let fraction = Double(step) / 100
            #expect(abs(InspectorSlide.ease(fraction) + InspectorSlide.ease(1 - fraction) - 1) < 0.001)
        }
    }

    @Test func theCurveIsClampedAtBothEnds() {
        #expect(InspectorSlide.ease(0) == 0)
        #expect(InspectorSlide.ease(1) == 1)
        #expect(InspectorSlide.ease(-3) == 0)
        #expect(InspectorSlide.ease(3) == 1)
    }

    @Test func itFinishesWhenTheTimeIsUp() {
        #expect(!slide.hasFinished(after: 0))
        #expect(!slide.hasFinished(after: 0.24))
        #expect(slide.hasFinished(after: 0.25))
        #expect(slide.hasFinished(after: 1))
    }

    @Test func aSlideNothingCanTimeIsOverBeforeItStarts() {
        // Both of these would otherwise be a display link that never invalidates itself, which is
        // a title bar layout pass every frame for as long as the window is open.
        let instant = InspectorSlide(from: 1, to: 381, seconds: 0)
        #expect(instant.hasFinished(after: 0))
        #expect(instant.width(after: 0) == 1)
        #expect(instant.width(after: 0.001) == 381)
        #expect(slide.hasFinished(after: .nan))
    }
}
