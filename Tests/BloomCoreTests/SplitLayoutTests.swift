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

    // MARK: - Moving

    /// The whole reason a move exists rather than a close followed by a split.
    ///
    /// A pane id is the tmux session name (`TmuxSessions.sessionName` makes `bloom_<workspace>_
    /// <pane>`) and the orphan sweep kills every session whose pane id nothing can enumerate. A
    /// move that renamed the pane would orphan the shell the user was working in, and the sweep
    /// would kill it at the next launch, with no way to get it back.
    @Test("moving a pane changes no pane's id")
    func moveKeepsEveryID() {
        var layout = nested()
        let before = Set(layout.panes)

        let didMove = layout.move("a", beside: "c", axis: .vertical, before: false)
        #expect(didMove)

        #expect(Set(layout.panes) == before)
        #expect(layout.paneCount == 3)
    }

    @Test("a pane moved below another lands under it")
    func moveBelow() {
        var layout = nested()
        let didMove = layout.move("a", beside: "c", axis: .vertical, before: false)
        #expect(didMove)

        #expect(layout.root == .split(
            axis: .vertical,
            ratio: 0.5,
            first: .pane("b"),
            second: .split(axis: .vertical, ratio: 0.5, first: .pane("c"), second: .pane("a"))
        ))
    }

    /// The leading and top edges are a real placement, not a split followed by an exchange of what
    /// the two panes hold. `WorkspaceTabsStore.split` does the exchange, which is harmless for a
    /// pane opening on new content and wrong for a pane being moved: it would carry the target's
    /// live shell into the pane that had just been made.
    @Test("a pane moved to the leading edge lands before its target")
    func moveBefore() {
        var layout = nested()
        let didMove = layout.move("c", beside: "a", axis: .horizontal, before: true)
        #expect(didMove)

        #expect(layout.root == .split(
            axis: .horizontal,
            ratio: 0.5,
            first: .split(axis: .horizontal, ratio: 0.5, first: .pane("c"), second: .pane("a")),
            second: .pane("b")
        ))
    }

    @Test("the moved pane takes the keyboard")
    func moveTakesFocus() {
        var layout = nested()
        let didFocus = layout.setFocus("b")
        #expect(didFocus)
        let didMove = layout.move("a", beside: "c", axis: .vertical, before: false)
        #expect(didMove)

        #expect(layout.focus == "a")
    }

    /// The space a moved pane leaves behind belongs to whatever grew into it, so the dissolved
    /// split's ratio goes with it and the new one opens at even shares. Every split the move did
    /// not touch keeps the size the user dragged it to.
    @Test("a move keeps the ratios of the splits it does not touch")
    func moveKeepsUntouchedRatios() {
        var layout = SplitLayout(pane: "a")
        layout.split("a", axis: .horizontal, into: "b")
        layout.split("b", axis: .vertical, into: "c")
        layout.split("c", axis: .horizontal, into: "d")
        // a | (b over (c | d)), with the innermost divider dragged well off centre.
        let didResize = layout.setRatio(0.8, at: [1, 1])
        #expect(didResize)

        let didMove = layout.move("a", beside: "b", axis: .vertical, before: true)
        #expect(didMove)

        #expect(layout.root == .split(
            axis: .vertical,
            ratio: 0.5,
            first: .split(axis: .vertical, ratio: 0.5, first: .pane("a"), second: .pane("b")),
            second: .split(axis: .horizontal, ratio: 0.8, first: .pane("c"), second: .pane("d"))
        ))
    }

    @Test("a move drops a zoom, because an arrangement nobody can see did not happen")
    func moveUnzooms() {
        var layout = nested()
        let didZoom = layout.toggleZoom()
        #expect(didZoom)
        #expect(layout.isZoomed)

        let didMove = layout.move("a", beside: "c", axis: .vertical, before: false)
        #expect(didMove)

        #expect(layout.zoomed == nil)
    }

    /// Performing it would not be free: the split holding the two would be dissolved and reopened
    /// at even shares, throwing away a divider the user had dragged to where they wanted it.
    @Test("a drop asking for the arrangement already on screen is refused")
    func moveOntoItsOwnPlace() {
        var layout = SplitLayout(pane: "a")
        layout.split("a", axis: .horizontal, into: "b")
        let didResize = layout.setRatio(0.3, at: [])
        #expect(didResize)

        let didMove = layout.move("a", beside: "b", axis: .horizontal, before: true)
        #expect(didMove == false)
        #expect(layout.root == .split(axis: .horizontal, ratio: 0.3, first: .pane("a"), second: .pane("b")))
    }

    @Test("the same two panes the other way round is a real move")
    func moveSwapsSiblings() {
        var layout = SplitLayout(pane: "a")
        layout.split("a", axis: .horizontal, into: "b")

        let didMove = layout.move("a", beside: "b", axis: .horizontal, before: false)
        #expect(didMove)
        #expect(layout.root == .split(axis: .horizontal, ratio: 0.5, first: .pane("b"), second: .pane("a")))
    }

    @Test("the same two panes on the other axis is a real move")
    func moveTurnsASplit() {
        var layout = SplitLayout(pane: "a")
        layout.split("a", axis: .horizontal, into: "b")

        let didMove = layout.move("a", beside: "b", axis: .vertical, before: true)
        #expect(didMove)
        #expect(layout.root == .split(axis: .vertical, ratio: 0.5, first: .pane("a"), second: .pane("b")))
    }

    @Test("a pane cannot be moved beside itself")
    func moveOntoItself() {
        var layout = nested()
        let didMove = layout.move("a", beside: "a", axis: .horizontal, before: false)
        #expect(didMove == false)
    }

    @Test("a pane the tab does not have is not a move")
    func moveUnknown() {
        var layout = nested()
        let didMove = layout.move("z", beside: "a", axis: .horizontal, before: false)
        #expect(didMove == false)
        let didMove2 = layout.move("a", beside: "z", axis: .horizontal, before: false)
        #expect(didMove2 == false)
        #expect(layout.root == nested().root)
    }

    /// A tab with one pane has nowhere to put it, which is the same answer `close` gives and for
    /// the same reason: the tab, not the layout, is what would have to change.
    @Test("the only pane of a tab has nowhere to move to")
    func moveTheOnlyPane() {
        var layout = SplitLayout(pane: "a")
        let didMove = layout.move("a", beside: "a", axis: .horizontal, before: false)
        #expect(didMove == false)
        #expect(layout.panes == ["a"])
    }

    @Test("a move survives a round trip through the stored form")
    func moveRoundTrips() throws {
        var layout = nested()
        let didMove = layout.move("a", beside: "c", axis: .vertical, before: false)
        #expect(didMove)

        let encoded = try #require(layout.encoded)
        #expect(SplitLayout(encoded: encoded) == layout)
    }

    /// A divider offers a pane to pick up only where its own child is one pane. Nothing is lost:
    /// every pane is a leaf and so a direct child of some split, which is the divider that offers
    /// it. In `a | (b over c)` the outer divider offers `a` and nothing opposite, and the inner one
    /// offers both of the others.
    @Test("a divider names the single pane on each of its sides, and says when there is not one")
    func sidesOfADivider() {
        let layout = nested()

        let outer = layout.sides(at: [])
        #expect(outer?.first == "a")
        #expect(outer?.second == nil)

        let inner = layout.sides(at: [1])
        #expect(inner?.first == "b")
        #expect(inner?.second == "c")
    }

    @Test("a path that names no split names no sides")
    func sidesOfNothing() {
        #expect(nested().sides(at: [0]) == nil)
        #expect(SplitLayout(pane: "a").sides(at: []) == nil)
    }

    // MARK: - Exchanging

    /// What a pane let go over the MIDDLE of another one means. A pane cannot be replaced the way
    /// a tab can, because the pane already there is a running shell or a loaded page and nothing
    /// about a drag says to end it.
    @Test("exchanging two panes puts each in the other's place")
    func exchange() {
        var layout = nested()
        let didExchange = layout.exchange("a", with: "c")
        #expect(didExchange)

        #expect(layout.root == .split(
            axis: .horizontal,
            ratio: 0.5,
            first: .pane("c"),
            second: .split(axis: .vertical, ratio: 0.5, first: .pane("b"), second: .pane("a"))
        ))
        #expect(layout.focus == "a")
    }

    @Test("an exchange leaves every split, axis and ratio exactly as it was")
    func exchangeKeepsShape() {
        var layout = nested()
        let didResize = layout.setRatio(0.2, at: [])
        #expect(didResize)
        let didResize2 = layout.setRatio(0.7, at: [1])
        #expect(didResize2)
        let geometry = layout.geometry(in: CGSize(width: 100, height: 100), dividerThickness: 0)

        let didExchange = layout.exchange("a", with: "b")
        #expect(didExchange)

        let after = layout.geometry(in: CGSize(width: 100, height: 100), dividerThickness: 0)
        #expect(after.panes.map(\.frame) == geometry.panes.map(\.frame))
        #expect(after.dividers == geometry.dividers)
        #expect(Set(layout.panes) == Set(nested().panes))
    }

    @Test("a pane cannot be exchanged with itself or with a stranger")
    func exchangeRefuses() {
        var layout = nested()
        let didExchange = layout.exchange("a", with: "a")
        #expect(didExchange == false)
        let didExchange2 = layout.exchange("a", with: "z")
        #expect(didExchange2 == false)
        #expect(layout.root == nested().root)
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

    /// The last three are the ones this was not defending against. A divider's ratio is a
    /// translation over a pane's own measure, and a pane briefly has no measure at all: during a
    /// layout pass before the geometry has arrived, and on a window restored to a zero rectangle.
    /// Both give a division that is not a number, `min` and `max` in Swift hand a NaN argument
    /// straight back, and the value went into the tree. `SplitNode.repaired` had the `isFinite`
    /// guard for a hand-edited defaults file and the live drag did not, which is the wrong way
    /// round: this is the path that runs sixty times a second.
    @Test(
        "no drag can take a pane to zero, or off the number line",
        arguments: [-4.0, 0, 0.001, 1, 40, .nan, .infinity, -.infinity]
    )
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
