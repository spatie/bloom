import CoreGraphics
import Foundation
import Testing
@testable import BloomCore

/// Where a drag over the centre column would land. In the core rather than in the pane's own view
/// because three things have to agree about it: the wash drawn while the pointer moves, the
/// refusal of a drop that would change nothing, and the edit itself.
@Suite("PaneLanding")
struct PaneLandingTests {
    private let size = CGSize(width: 400, height: 200)

    /// a | b, which is what one Cmd+D leaves.
    private func sideBySide() -> SplitGeometry {
        var layout = SplitLayout(pane: "a")
        layout.split("a", axis: .horizontal, into: "b")
        return layout.geometry(in: size, dividerThickness: 0)
    }

    // MARK: - Regions

    @Test("the middle of a pane is the middle")
    func middle() {
        #expect(PaneRegion.at(CGPoint(x: 200, y: 100), in: size) == .whole)
    }

    @Test("each edge is a quarter of the pane along that side")
    func edges() {
        #expect(PaneRegion.at(CGPoint(x: 99, y: 100), in: size) == .leading)
        #expect(PaneRegion.at(CGPoint(x: 101, y: 100), in: size) == .whole)
        #expect(PaneRegion.at(CGPoint(x: 301, y: 100), in: size) == .trailing)
        #expect(PaneRegion.at(CGPoint(x: 200, y: 49), in: size) == .top)
        #expect(PaneRegion.at(CGPoint(x: 200, y: 151), in: size) == .bottom)
    }

    /// Arbitrary and consistent beats predictable-sounding and unpredictable. The two readings of
    /// a corner differ over a sixteenth of the pane, and the horizontal pair is tested first.
    @Test("a corner belongs to the side rather than to the top or bottom")
    func corners() {
        #expect(PaneRegion.at(CGPoint(x: 10, y: 10), in: size) == .leading)
        #expect(PaneRegion.at(CGPoint(x: 390, y: 190), in: size) == .trailing)
    }

    @Test("a pane with no size at all is all middle")
    func degenerate() {
        #expect(PaneRegion.at(.zero, in: .zero) == .whole)
        #expect(PaneRegion.at(CGPoint(x: 5, y: 5), in: CGSize(width: 0, height: 10)) == .whole)
    }

    // MARK: - What a region means

    @Test("the middle is not a placement, and each edge is one")
    func placements() {
        #expect(PaneRegion.whole.placement == nil)

        #expect(PaneRegion.leading.placement?.axis == .horizontal)
        #expect(PaneRegion.leading.placement?.before == true)
        #expect(PaneRegion.trailing.placement?.axis == .horizontal)
        #expect(PaneRegion.trailing.placement?.before == false)
        #expect(PaneRegion.top.placement?.axis == .vertical)
        #expect(PaneRegion.top.placement?.before == true)
        #expect(PaneRegion.bottom.placement?.axis == .vertical)
        #expect(PaneRegion.bottom.placement?.before == false)
    }

    // MARK: - The rectangle to wash

    @Test("the middle washes the whole pane and an edge washes a quarter of it")
    func washes() {
        let pane = CGRect(x: 100, y: 50, width: 400, height: 200)

        #expect(PaneRegion.whole.frame(in: pane) == pane)
        #expect(PaneRegion.leading.frame(in: pane) == CGRect(x: 100, y: 50, width: 100, height: 200))
        #expect(PaneRegion.trailing.frame(in: pane) == CGRect(x: 400, y: 50, width: 100, height: 200))
        #expect(PaneRegion.top.frame(in: pane) == CGRect(x: 100, y: 50, width: 400, height: 50))
        #expect(PaneRegion.bottom.frame(in: pane) == CGRect(x: 100, y: 200, width: 400, height: 50))
    }

    /// Every wash is inside the pane it describes, whichever region it is. A wash that reached past
    /// the pane would be describing a drop into the pane next door.
    @Test("no wash escapes the pane it belongs to")
    func washesStayInside() {
        let pane = CGRect(x: 12, y: 34, width: 321, height: 123)
        for region in PaneRegion.allCases {
            #expect(pane.contains(region.frame(in: pane)))
        }
    }

    // MARK: - Finding the pane

    @Test("a point picks out the pane it is in and the part of it")
    func landingInAPane() {
        let geometry = sideBySide()

        let left = geometry.landing(at: CGPoint(x: 100, y: 100))
        #expect(left?.pane == "a")
        #expect(left?.region == .whole)

        let rightEdgeOfLeft = geometry.landing(at: CGPoint(x: 195, y: 100))
        #expect(rightEdgeOfLeft?.pane == "a")
        #expect(rightEdgeOfLeft?.region == .trailing)

        let right = geometry.landing(at: CGPoint(x: 300, y: 100))
        #expect(right?.pane == "b")
        #expect(right?.region == .whole)
    }

    /// The frame comes back in the column's own space, not the pane's, because it is drawn over the
    /// column. A trailing wash on the left pane of a 400 point column starts at 150 and not at 50.
    @Test("the wash comes back in the column's coordinates")
    func landingFrameIsAbsolute() {
        let landing = sideBySide().landing(at: CGPoint(x: 195, y: 100))

        #expect(landing?.frame == CGRect(x: 150, y: 0, width: 50, height: 200))
    }

    @Test("a point outside every pane lands nowhere")
    func landingOutside() {
        let geometry = sideBySide()

        #expect(geometry.landing(at: CGPoint(x: -1, y: 100)) == nil)
        #expect(geometry.landing(at: CGPoint(x: 401, y: 100)) == nil)
        #expect(geometry.landing(at: CGPoint(x: 200, y: 201)) == nil)
    }

    /// A divider is a few pixels between two panes, and guessing which of them somebody meant is
    /// how a drag lands in the wrong half. It lands nowhere and does nothing instead.
    @Test("a point on a divider lands nowhere rather than being snapped to a neighbour")
    func landingOnADivider() {
        var layout = SplitLayout(pane: "a")
        layout.split("a", axis: .horizontal, into: "b")
        let geometry = layout.geometry(in: size, dividerThickness: 10)

        #expect(geometry.dividers.first?.frame.minX == 195)
        #expect(geometry.landing(at: CGPoint(x: 200, y: 100)) == nil)
    }

    @Test("a tab that has never been split is one pane covering the whole column")
    func landingInASinglePane() {
        let geometry = SplitLayout(pane: "only").geometry(in: size, dividerThickness: 0)

        #expect(geometry.landing(at: CGPoint(x: 200, y: 100))?.pane == "only")
        #expect(geometry.landing(at: CGPoint(x: 10, y: 100))?.region == .leading)
    }

    /// A zoomed tab draws one pane and no dividers, so every point in the column is that pane.
    @Test("a zoomed pane is the whole column")
    func landingWhileZoomed() {
        var layout = SplitLayout(pane: "a")
        layout.split("a", axis: .horizontal, into: "b")
        _ = layout.toggleZoom()
        let geometry = layout.geometry(in: size, dividerThickness: 0)

        #expect(geometry.landing(at: CGPoint(x: 10, y: 100))?.pane == "b")
        #expect(geometry.landing(at: CGPoint(x: 390, y: 100))?.pane == "b")
    }

    /// Every pane the tree draws can be landed in, and a landing always names a pane the tree has.
    @Test("a nested tree can be landed in anywhere it draws a pane")
    func landingInANestedTree() {
        var layout = SplitLayout(pane: "a")
        layout.split("a", axis: .horizontal, into: "b")
        layout.split("b", axis: .vertical, into: "c")
        let geometry = layout.geometry(in: size, dividerThickness: 0)

        var found: Set<String> = []
        for frame in geometry.panes {
            let landing = geometry.landing(at: CGPoint(x: frame.frame.midX, y: frame.frame.midY))
            #expect(landing?.pane == frame.pane)
            #expect(landing?.region == .whole)
            if let pane = landing?.pane { found.insert(pane) }
        }
        #expect(found == Set(layout.panes))
    }
}
