import Testing
import CoreGraphics
import Foundation
@testable import BloomCore

@Suite("SplitLayout")
struct SplitLayoutTests {
    // MARK: - Splitting

    @Test("a fresh layout is one pane holding the keyboard")
    func single() {
        let layout = SplitLayout(pane: "a")

        #expect(layout.panes == ["a"])
        #expect(layout.focus == "a")
        #expect(layout.zoomed == nil)
        #expect(layout.root == .pane("a"))
    }

    @Test("splitting side by side puts the new pane on the right")
    func splitHorizontally() {
        var layout = SplitLayout(pane: "a")
        let didSplit = layout.split("a", axis: .horizontal, into: "b")
        #expect(didSplit)

        #expect(layout.root == .split(axis: .horizontal, ratio: 0.5, first: .pane("a"), second: .pane("b")))
        #expect(layout.panes == ["a", "b"])
        // The new pane takes the keyboard, which is what every terminal on this platform does.
        #expect(layout.focus == "b")

        let frames = layout.geometry(in: CGSize(width: 100, height: 40), dividerThickness: 0).panes
        #expect(frames[0].frame == CGRect(x: 0, y: 0, width: 50, height: 40))
        #expect(frames[1].frame == CGRect(x: 50, y: 0, width: 50, height: 40))
    }

    @Test("splitting stacked puts the new pane below")
    func splitVertically() {
        var layout = SplitLayout(pane: "a")
        layout.split("a", axis: .vertical, into: "b")

        let frames = layout.geometry(in: CGSize(width: 100, height: 40), dividerThickness: 0).panes
        #expect(frames[0].frame == CGRect(x: 0, y: 0, width: 100, height: 20))
        #expect(frames[1].frame == CGRect(x: 0, y: 20, width: 100, height: 20))
    }

    @Test("splitting a pane that is already inside a split only touches that pane")
    func splitNested() {
        var layout = SplitLayout(pane: "a")
        layout.split("a", axis: .horizontal, into: "b")
        layout.split("b", axis: .vertical, into: "c")

        #expect(layout.root == .split(
            axis: .horizontal,
            ratio: 0.5,
            first: .pane("a"),
            second: .split(axis: .vertical, ratio: 0.5, first: .pane("b"), second: .pane("c"))
        ))
        #expect(layout.panes == ["a", "b", "c"])

        let frames = layout.geometry(in: CGSize(width: 100, height: 40), dividerThickness: 0).panes
        #expect(frames[0].frame == CGRect(x: 0, y: 0, width: 50, height: 40))
        #expect(frames[1].frame == CGRect(x: 50, y: 0, width: 50, height: 20))
        #expect(frames[2].frame == CGRect(x: 50, y: 20, width: 50, height: 20))
    }

    @Test("a split keeps the ratios of the splits above it")
    func splitKeepsRatios() {
        var layout = SplitLayout(pane: "a")
        layout.split("a", axis: .horizontal, into: "b")
        layout.setRatio(0.8, at: [])
        layout.split("b", axis: .horizontal, into: "c")

        #expect(layout.ratio(at: []) == 0.8)
        #expect(layout.ratio(at: [1]) == 0.5)
    }

    @Test("a pane that is not there cannot be split, and an id cannot be used twice")
    func splitRejects() {
        var layout = SplitLayout(pane: "a")
        let didSplit = layout.split("missing", axis: .horizontal, into: "b")
        #expect(didSplit == false)
        layout.split("a", axis: .horizontal, into: "b")
        let didSplit2 = layout.split("a", axis: .horizontal, into: "b")
        #expect(didSplit2 == false)
        #expect(layout.panes == ["a", "b"])
    }

    @Test("splitting a zoomed pane shows the split")
    func splitUnzooms() {
        var layout = SplitLayout(pane: "a")
        layout.split("a", axis: .horizontal, into: "b")
        layout.toggleZoom()
        #expect(layout.isZoomed)

        layout.split("b", axis: .vertical, into: "c")
        #expect(layout.isZoomed == false)
    }

    // MARK: - Closing

    @Test("closing a pane collapses its split, leaving no empty node behind")
    func closeCollapses() {
        var layout = SplitLayout(pane: "a")
        layout.split("a", axis: .horizontal, into: "b")
        let didClose = layout.close("b")
        #expect(didClose)

        #expect(layout.root == .pane("a"))
        #expect(layout.focus == "a")
        #expect(layout.paneCount == 1)
    }

    @Test("closing a pane deep in the tree collapses only its own split")
    func closeCollapsesNested() {
        var layout = SplitLayout(pane: "a")
        layout.split("a", axis: .horizontal, into: "b")
        layout.split("b", axis: .vertical, into: "c")
        layout.setRatio(0.7, at: [])

        let didClose = layout.close("c")
        #expect(didClose)
        #expect(layout.root == .split(axis: .horizontal, ratio: 0.7, first: .pane("a"), second: .pane("b")))
        #expect(layout.focus == "b")
    }

    @Test("the survivor takes the whole of the space the two panes shared")
    func closeGivesSpaceToSurvivor() {
        var layout = SplitLayout(pane: "a")
        layout.split("a", axis: .horizontal, into: "b")
        layout.split("b", axis: .vertical, into: "c")
        layout.close("b")

        let frames = layout.geometry(in: CGSize(width: 100, height: 40), dividerThickness: 0).panes
        #expect(frames.count == 2)
        #expect(frames[1].frame == CGRect(x: 50, y: 0, width: 50, height: 40))
    }

    @Test("closing the focused pane moves the keyboard to the one that grew into its place")
    func closeMovesFocus() {
        var layout = SplitLayout(pane: "a")
        layout.split("a", axis: .horizontal, into: "b")
        layout.split("a", axis: .vertical, into: "c")
        layout.setFocus("c")

        layout.close("c")
        #expect(layout.focus == "a")
    }

    @Test("closing the last pane is refused and changes nothing")
    func closeLast() {
        var layout = SplitLayout(pane: "a")
        let didClose = layout.close("a")
        #expect(didClose == false)
        #expect(layout.root == .pane("a"))
        #expect(layout.focus == "a")
    }

    @Test("closing a pane that is not there is refused")
    func closeUnknown() {
        var layout = SplitLayout(pane: "a")
        layout.split("a", axis: .horizontal, into: "b")
        let didClose = layout.close("c")
        #expect(didClose == false)
        #expect(layout.paneCount == 2)
    }

    @Test("closing the zoomed pane leaves the rest unzoomed")
    func closeZoomed() {
        var layout = SplitLayout(pane: "a")
        layout.split("a", axis: .horizontal, into: "b")
        layout.toggleZoom()
        layout.close("b")

        #expect(layout.isZoomed == false)
        #expect(layout.panes == ["a"])
    }

    @Test("closing every pane but one empties the tree down to a bare pane")
    func closeDownToOne() {
        var layout = SplitLayout(pane: "a")
        layout.split("a", axis: .horizontal, into: "b")
        layout.split("b", axis: .vertical, into: "c")
        layout.split("c", axis: .horizontal, into: "d")

        layout.close("d")
        layout.close("c")
        layout.close("b")

        #expect(layout.root == .pane("a"))
        let didClose = layout.close("a")
        #expect(didClose == false)
    }

    // MARK: - Neighbours

    /// a | b over c, the arrangement Cmd+D then Shift+Cmd+D produces.
    private func nested() -> SplitLayout {
        var layout = SplitLayout(pane: "a")
        layout.split("a", axis: .horizontal, into: "b")
        layout.split("b", axis: .vertical, into: "c")
        return layout
    }

    @Test("neighbours in a plain side by side split")
    func neighbourSideBySide() {
        var layout = SplitLayout(pane: "a")
        layout.split("a", axis: .horizontal, into: "b")

        #expect(layout.neighbour(of: "a", direction: .right) == "b")
        #expect(layout.neighbour(of: "b", direction: .left) == "a")
        #expect(layout.neighbour(of: "a", direction: .left) == nil)
        #expect(layout.neighbour(of: "a", direction: .up) == nil)
        #expect(layout.neighbour(of: "a", direction: .down) == nil)
    }

    @Test("the neighbour to the right can be nested deeper than the pane looking for it")
    func neighbourNestedDeeper() {
        let layout = nested()

        // `a` is full height and faces two half height panes, which share its edge equally. The
        // upper one wins, the same way a move right in iTerm lands on the topmost of a stack.
        #expect(layout.neighbour(of: "a", direction: .right) == "b")
        #expect(layout.neighbour(of: "b", direction: .left) == "a")
        #expect(layout.neighbour(of: "c", direction: .left) == "a")
        #expect(layout.neighbour(of: "b", direction: .down) == "c")
        #expect(layout.neighbour(of: "c", direction: .up) == "b")
        #expect(layout.neighbour(of: "b", direction: .up) == nil)
        #expect(layout.neighbour(of: "c", direction: .right) == nil)
    }

    @Test("a move across a divider crosses to the pane that shares most of the edge")
    func neighbourPrefersOverlap() {
        var layout = SplitLayout(pane: "a")
        layout.split("a", axis: .horizontal, into: "b")
        layout.split("b", axis: .vertical, into: "c")
        // Most of the right hand column is `c` now, so a move right from `a` lands there.
        layout.setRatio(0.2, at: [1])

        #expect(layout.neighbour(of: "a", direction: .right) == "c")
    }

    @Test("moving focus follows the neighbour, and does nothing when there is none")
    func moveFocus() {
        var layout = nested()
        layout.setFocus("a")

        let didMove = layout.moveFocus(.right)
        #expect(didMove)
        #expect(layout.focus == "b")
        let didMove2 = layout.moveFocus(.down)
        #expect(didMove2)
        #expect(layout.focus == "c")
        let didMove3 = layout.moveFocus(.right)
        #expect(didMove3 == false)
        #expect(layout.focus == "c")
    }

    @Test("a zoomed pane has nothing to move to")
    func moveFocusWhileZoomed() {
        var layout = nested()
        layout.toggleZoom()

        let didMove = layout.moveFocus(.left)
        #expect(didMove == false)
    }

    // MARK: - Resizing

    @Test("a divider moves the split it names and leaves the others alone")
    func resize() {
        var layout = nested()
        let didResize = layout.setRatio(0.25, at: [])
        #expect(didResize)

        #expect(layout.ratio(at: []) == 0.25)
        #expect(layout.ratio(at: [1]) == 0.5)

        let frames = layout.geometry(in: CGSize(width: 100, height: 40), dividerThickness: 0).panes
        #expect(frames[0].frame == CGRect(x: 0, y: 0, width: 25, height: 40))
        #expect(frames[1].frame == CGRect(x: 25, y: 0, width: 75, height: 20))
    }

    @Test("a nested divider is reachable by its path")
    func resizeNested() {
        var layout = nested()
        let didResize = layout.setRatio(0.75, at: [1])
        #expect(didResize)
        #expect(layout.ratio(at: [1]) == 0.75)
        #expect(layout.ratio(at: []) == 0.5)
    }

    @Test("no drag can take a pane to zero", arguments: [-4.0, 0, 0.001, 1, 40])
    func resizeClamps(ratio: Double) throws {
        var layout = SplitLayout(pane: "a")
        layout.split("a", axis: .horizontal, into: "b")
        layout.setRatio(ratio, at: [])

        let value = try #require(layout.ratio(at: []))
        #expect(value >= SplitLayout.minimumRatio)
        #expect(value <= 1 - SplitLayout.minimumRatio)

        let frames = layout.geometry(in: CGSize(width: 100, height: 40), dividerThickness: 0).panes
        #expect(frames[0].frame.width > 0)
        #expect(frames[1].frame.width > 0)
    }

    @Test("a path that names no split is refused")
    func resizeUnknownPath() {
        var layout = SplitLayout(pane: "a")
        let didResize = layout.setRatio(0.3, at: [])
        #expect(didResize == false)
        layout.split("a", axis: .horizontal, into: "b")
        let didResize2 = layout.setRatio(0.3, at: [0])
        #expect(didResize2 == false)
        let didResize3 = layout.setRatio(0.3, at: [0, 1])
        #expect(didResize3 == false)
    }

    // MARK: - Geometry

    @Test("the divider takes its thickness out of the split, never out of the window")
    func dividerThickness() throws {
        var layout = SplitLayout(pane: "a")
        layout.split("a", axis: .horizontal, into: "b")

        let geometry = layout.geometry(in: CGSize(width: 101, height: 40), dividerThickness: 1)
        #expect(geometry.panes[0].frame == CGRect(x: 0, y: 0, width: 50, height: 40))
        #expect(geometry.panes[1].frame == CGRect(x: 51, y: 0, width: 50, height: 40))

        let divider = try #require(geometry.dividers.first)
        #expect(divider.frame == CGRect(x: 50, y: 0, width: 1, height: 40))
        #expect(divider.span == 100)
        #expect(divider.path.isEmpty)
        #expect(divider.axis == .horizontal)
    }

    @Test("every split has exactly one divider, and its path leads back to it")
    func dividerPaths() {
        let layout = nested()
        let dividers = layout.geometry(in: CGSize(width: 100, height: 40), dividerThickness: 1).dividers

        #expect(dividers.count == 2)
        #expect(Set(dividers.map(\.path)) == [[], [1]])
        for divider in dividers {
            #expect(layout.ratio(at: divider.path) == divider.ratio)
        }
    }

    @Test("a zoomed pane fills the tab and hides every divider")
    func zoomGeometry() {
        var layout = nested()
        layout.setFocus("b")
        layout.toggleZoom()

        let geometry = layout.geometry(in: CGSize(width: 100, height: 40), dividerThickness: 1)
        #expect(geometry.panes == [SplitPaneFrame(pane: "b", frame: CGRect(x: 0, y: 0, width: 100, height: 40))])
        #expect(geometry.dividers.isEmpty)

        layout.toggleZoom()
        #expect(layout.geometry(in: CGSize(width: 100, height: 40), dividerThickness: 1).panes.count == 3)
    }

    @Test("one pane has nothing to zoom")
    func zoomSinglePane() {
        var layout = SplitLayout(pane: "a")
        let didZoom = layout.toggleZoom()
        #expect(didZoom == false)
        #expect(layout.isZoomed == false)
    }

    // MARK: - Persistence

    @Test("a layout survives the round trip it is persisted through")
    func roundTrip() throws {
        var layout = nested()
        layout.setRatio(0.3, at: [])
        layout.setRatio(0.65, at: [1])
        layout.setFocus("c")
        layout.toggleZoom()

        let encoded = try #require(layout.encoded)
        let decoded = try #require(SplitLayout(encoded: encoded))

        #expect(decoded == layout)
        #expect(decoded.root == layout.root)
        #expect(decoded.focus == "c")
        #expect(decoded.zoomed == "c")
        #expect(decoded.ratio(at: [1]) == 0.65)
    }

    @Test("a single pane round trips too")
    func roundTripSingle() throws {
        let layout = SplitLayout(pane: "a")
        let encoded = try #require(layout.encoded)
        #expect(try #require(SplitLayout(encoded: encoded)) == layout)
    }

    /// Measured rather than assumed: two encodings of one tree used to come out as
    /// `{"focus":...,"root":...}` and `{"root":...,"focus":...}` in the same process. Phase A of
    /// the tab migration writes its new key before it deletes the old one, so a crash between
    /// those two lines leaves it to run again, and it converges only if it lands on the same bytes.
    @Test("the same tree always encodes to the same bytes")
    func encodingIsStable() throws {
        var layout = nested()
        layout.setRatio(0.3, at: [])
        layout.setFocus("c")

        let once = try #require(layout.encoded)
        let twice = try #require(layout.encoded)
        let round = try #require(SplitLayout(encoded: once))

        #expect(once == twice)
        #expect(round.encoded == once)
    }

    @Test("nonsense in user defaults is not a layout")
    func decodeGarbage() {
        #expect(SplitLayout(encoded: "") == nil)
        #expect(SplitLayout(encoded: "{}") == nil)
        #expect(SplitLayout(encoded: "not json at all") == nil)
    }

    @Test("a decoded layout naming panes it does not have is repaired rather than trusted")
    func decodeRepairs() throws {
        var layout = SplitLayout(pane: "a")
        layout.split("a", axis: .horizontal, into: "b")
        let encoded = try #require(layout.encoded)
            .replacingOccurrences(of: "\"focus\":\"b\"", with: "\"focus\":\"gone\"")

        let decoded = try #require(SplitLayout(encoded: encoded))
        #expect(decoded.focus == "a")
        #expect(decoded.panes == ["a", "b"])
    }
}
