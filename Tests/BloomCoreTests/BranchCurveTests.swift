import CoreGraphics
import Foundation
import Testing
@testable import BloomCore

/// The welcome window's branches, pinned where the view cannot be reached.
///
/// Only the arithmetic is here. Colour, timing and the frame rate cap live in `BrandBranching`
/// and nothing in this target can see them, so what is worth writing down is the part that would
/// be wrong without anybody noticing: a branch that does not come back to the spine, a run on the
/// wrong side of it, and a light that speeds up in the turns.
struct BranchCurveTests {
    @Test func bothEndsSitOnTheSpine() {
        let points = BranchCurve.shape(from: 20, to: 300, spine: 140, rise: -60, crown: 8)

        #expect(points.first?.x.isApproximately(20) == true)
        #expect(points.first?.y.isApproximately(140) == true)
        #expect(points.last?.x.isApproximately(300) == true)
        #expect(points.last?.y.isApproximately(140) == true)
    }

    @Test func theRunStaysOnTheSideItWasAskedFor() {
        let above = BranchCurve.shape(from: 0, to: 400, spine: 100, rise: 70, crown: 10)
        let below = BranchCurve.shape(from: 0, to: 400, spine: 100, rise: -70, crown: 10)

        #expect(above.allSatisfy { $0.y >= 100 })
        #expect(below.allSatisfy { $0.y <= 100 })
        // The camber bows the run further from the spine, never back towards it.
        #expect((above.map(\.y).max() ?? 0) > 170)
        #expect((below.map(\.y).min() ?? 0) < 30)
    }

    @Test func theLineOnlyEverGoesForwards() {
        let points = BranchCurve.shape(from: 12, to: 380, spine: 90, rise: -80, crown: 6)

        for (previous, next) in zip(points, points.dropFirst()) {
            #expect(next.x >= previous.x - 0.001)
        }
    }

    /// A short branch is the case the ceiling on `lead` exists for: without it the two turns
    /// overlap and the run doubles back on itself.
    @Test func aShortBranchStillOnlyGoesForwards() {
        let points = BranchCurve.shape(from: 0, to: 60, spine: 50, rise: 40, crown: 6)

        for (previous, next) in zip(points, points.dropFirst()) {
            #expect(next.x >= previous.x - 0.001)
        }
        #expect(points.last?.y.isApproximately(50) == true)
    }

    @Test func aBranchWithNoWidthIsOnePoint() {
        #expect(BranchCurve.shape(from: 100, to: 100, spine: 10, rise: 20).count == 1)
        #expect(BranchCurve.shape(from: 200, to: 100, spine: 10, rise: 20).count == 1)
    }

    @Test func pacingPutsEveryStepTheSameDistanceApart() {
        let points = BranchCurve.shape(from: 0, to: 420, spine: 120, rise: -75, crown: 9)
        let paced = BranchCurve.paced(points, count: 40)

        #expect(paced.count == 40)

        let steps = zip(paced, paced.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        let longest = steps.max() ?? 0
        let shortest = steps.min() ?? 0
        // A chord across a curve is always shorter than the arc it cuts, so the steps can never
        // be exactly equal. Within a couple of percent is what a travelling light needs.
        #expect(longest - shortest < longest * 0.03)
    }

    @Test func pacingKeepsBothEnds() {
        let points = BranchCurve.shape(from: 30, to: 260, spine: 80, rise: 55)
        let paced = BranchCurve.paced(points, count: 24)

        #expect(paced.first?.x.isApproximately(30) == true)
        #expect(paced.last?.x.isApproximately(260) == true)
        #expect(paced.last?.y.isApproximately(80) == true)
    }

    @Test func pacingAnEmptyOrSinglePointLineGivesItBack() {
        #expect(BranchCurve.paced([], count: 20).isEmpty)
        #expect(BranchCurve.paced([CGPoint(x: 1, y: 2)], count: 20).count == 1)
        #expect(BranchCurve.paced([CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)], count: 1).count == 2)
    }

    @Test func lengthIsTheWalkAlongTheLineAndNotTheDistanceAcrossIt() {
        let points = BranchCurve.shape(from: 0, to: 300, spine: 100, rise: -90, crown: 10)

        #expect(BranchCurve.length(of: points) > 300)
        #expect(BranchCurve.length(of: []) == 0)
    }
}

private extension CGFloat {
    func isApproximately(_ other: CGFloat) -> Bool { abs(self - other) < 0.001 }
}
