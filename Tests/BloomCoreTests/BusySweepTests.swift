import Foundation
import Testing
@testable import BloomCore

/// Safari's loading sweep, through a busy tab and along a column with no strip. The owner chose it
/// off a mockup, so these are that mockup's numbers and the properties a sweep has to have to look
/// like one.
@Suite("The busy sweep")
struct BusySweepTests {
    private static let bands: [(String, BusySweep.Band)] = [("tab", BusySweep.tab), ("column", BusySweep.column)]

    @Test("the mockup's figures")
    func mockupFigures() {
        #expect(BusySweep.period == 1.6)
        #expect(BusySweep.fade == 0.25)
        #expect(BusySweep.curve == (x1: 0.45, y1: 0.05, x2: 0.55, y2: 0.95))
        #expect(BusySweep.tab.widthShare == 0.55)
        #expect(BusySweep.tab.stops.map(\.location) == [0, 0.45, 0.55, 1])
        #expect(BusySweep.tab.stops.map(\.strength) == [0, 1, 1, 0])
        // `background-position: -120%` and `220%` on a background 55 per cent wide.
        #expect(abs(BusySweep.tab.leadingFrom - -0.54) < 1e-9)
        #expect(abs(BusySweep.tab.leadingTo - 0.99) < 1e-9)
        #expect(BusySweep.column.widthShare == 0.35)
        #expect(BusySweep.column.stops.map(\.location) == [0, 0.3, 0.7, 1])
        #expect(BusySweep.column.leadingFrom == -0.35)
        #expect(BusySweep.column.leadingTo == 1)
        #expect(BusySweep.columnThickness == 2.5)
        #expect(BusySweep.tabBand.light == 0.34)
        #expect(BusySweep.tabWash.light == 0.08)
    }

    /// The crossing wraps from its end back to its start in one frame, so at both ends nothing that
    /// draws may be on the track, or the wrap is a jump.
    @Test("nothing drawn is on the track at either end of a crossing")
    func wrapsInvisibly() {
        for (name, band) in Self.bands {
            let reach = band.visibleReach
            #expect(reach.atStart <= 0, "\(name) is \(reach.atStart) onto the track as it starts")
            #expect(reach.atEnd >= 1, "\(name) is still \(1 - reach.atEnd) on the track as it ends")
        }
    }

    @Test("it crosses from the leading edge to the trailing one")
    func travelsLeadingToTrailing() {
        for (_, band) in Self.bands {
            let edges = [0.0, 0.25, 0.5, 0.75, 1].map(band.leadingEdge(at:))
            #expect(zip(edges.dropFirst(), edges).allSatisfy { $0 > $1 })
            // Within rounding: `from + (to - from) * 1` is not always `to` in binary.
            #expect(abs(band.leadingEdge(at: 0) - band.leadingFrom) < 1e-12)
            #expect(abs(band.leadingEdge(at: 1) - band.leadingTo) < 1e-12)
        }
    }

    /// The anchor is what the layer animates, so it has to put the band's leading edge where the
    /// figure says at every width, with the same two values. That is what lets a resized tab keep
    /// its band without rebuilding the animation.
    @Test("one pair of anchors places the band at any width")
    func anchorIsWidthIndependent() {
        for (_, band) in Self.bands {
            for width in [110.0, 163.5, 200, 760, 1400] {
                let bandWidth = band.widthShare * width
                for progress in [0.0, 0.3, 1] {
                    let leading = band.leadingEdge(at: progress)
                    let anchor = band.anchor(atLeadingEdge: leading)
                    // A layer positioned at x = 0 with this anchor has its leading edge here.
                    let placed = 0 - anchor * bandWidth
                    #expect(abs(placed - leading * width) < 1e-9)
                }
            }
        }
    }

    /// The reason sixty frames a second is enough: at the fastest point of the fastest figure, one
    /// frame moves the column's segment well under the width of its soft end.
    @Test("a frame at the cap moves the segment less than a third of its soft end")
    func stepsInsideTheRamp() {
        let width = 760.0
        let band = BusySweep.column
        let travel = (band.leadingTo - band.leadingFrom) * width
        let peakStep = travel / BusySweep.period * BusySweep.peakSpeedFactor / BusySweep.frameRate
        let ramp = band.stops[1].location * band.widthShare * width
        #expect(abs(BusySweep.peakSpeedFactor - 1.727) < 0.001)
        #expect(peakStep < ramp / 3, "a \(peakStep) point step against a \(ramp) point ramp")
    }

    @Test("every dark tint is stronger than its light one, because the house fill is one value")
    func darkIsStronger() {
        for strength in [BusySweep.tabBand, BusySweep.tabWash, BusySweep.tabStill, BusySweep.columnStill] {
            #expect(strength.dark > strength.light)
            #expect(strength.member(dark: true) == strength.dark)
            #expect(strength.member(dark: false) == strength.light)
        }
    }
}
