import Testing
@testable import BloomCore

/// The rules between tabs, as Safari draws them: only between two tabs at rest.
@Suite("TabStripDividers")
struct TabStripDividersTests {
    @Test("a strip of fewer than two tabs has no gap")
    func noGaps() {
        #expect(TabStripDividers.visible(count: 0, selected: nil, hovered: nil, dragged: nil).isEmpty)
        #expect(TabStripDividers.visible(count: 1, selected: 0, hovered: nil, dragged: nil).isEmpty)
    }

    @Test("every gap between resting tabs shows a divider")
    func allAtRest() {
        #expect(TabStripDividers.visible(count: 4, selected: nil, hovered: nil, dragged: nil)
            == [true, true, true])
    }

    /// Safari's own screenshot: four tabs with the last one selected has a rule between the first
    /// three and none against the selected one.
    @Test("no divider beside the selected tab")
    func selectedLast() {
        #expect(TabStripDividers.visible(count: 4, selected: 3, hovered: nil, dragged: nil)
            == [true, true, false])
        #expect(TabStripDividers.visible(count: 4, selected: 1, hovered: nil, dragged: nil)
            == [false, false, true])
    }

    /// Hovering the first tab takes the rule between it and the second, and leaves the one
    /// between the second and the third.
    @Test("a hovered tab hides the dividers on both of its sides and no others")
    func hovered() {
        #expect(TabStripDividers.visible(count: 4, selected: 3, hovered: 0, dragged: nil)
            == [false, true, false])
        #expect(TabStripDividers.visible(count: 5, selected: nil, hovered: 2, dragged: nil)
            == [true, false, false, true])
    }

    @Test("hovering the selected tab hides nothing more")
    func hoveredSelected() {
        #expect(TabStripDividers.visible(count: 3, selected: 1, hovered: 1, dragged: nil)
            == [false, false])
    }

    @Test("the dragged tab's slot hides its neighbouring dividers")
    func dragged() {
        #expect(TabStripDividers.visible(count: 4, selected: 0, hovered: nil, dragged: 2)
            == [false, false, false])
        #expect(TabStripDividers.visible(count: 4, selected: nil, hovered: nil, dragged: 3)
            == [true, true, false])
    }

    @Test("a slot outside the strip hides nothing")
    func outOfRange() {
        #expect(TabStripDividers.visible(count: 3, selected: -1, hovered: 3, dragged: 7)
            == [true, true])
    }

    /// During a drag the slots are where the tabs are drawn, so the rule that goes is the one
    /// beside the slot the carried tab has slid into rather than the one it started beside.
    @Test("slots are read off the order the strip is drawing")
    func drawnOrder() {
        let drawn = ["b", "c", "a", "d"]
        #expect(TabStripDividers.visible(in: drawn, selected: "d", hovered: nil, dragged: "a")
            == [true, false, false])
    }

    @Test("a tab missing from the order occupies no slot")
    func missingItem() {
        #expect(TabStripDividers.visible(in: ["a", "b", "c"], selected: "gone", hovered: "b", dragged: nil)
            == [false, false])
        #expect(TabStripDividers.visible(in: ["a", "b", "c"], selected: nil, hovered: "gone", dragged: nil)
            == [true, true])
    }

    /// A busy tab wears a capsule of its own, so the rules against it go the way they do against
    /// the selected one, and a rule between two tabs at rest elsewhere stays.
    @Test("a busy tab hides the dividers on both of its sides")
    func busy() {
        #expect(TabStripDividers.visible(count: 5, selected: 0, hovered: nil, dragged: nil, busy: [3])
            == [false, true, false, false])
        #expect(TabStripDividers.visible(count: 4, selected: nil, hovered: nil, dragged: nil, busy: [0, 1])
            == [false, false, true])
        // Busy and selected at once hides nothing more than selected does.
        #expect(TabStripDividers.visible(count: 3, selected: 1, hovered: nil, dragged: nil, busy: [1])
            == [false, false])
        #expect(TabStripDividers.visible(count: 3, selected: nil, hovered: nil, dragged: nil, busy: [9])
            == [true, true])
    }

    /// While a tab is carried, the busy tab's rules are the ones beside the slot it has slid into.
    @Test("a busy tab is found in the order the strip is drawing")
    func busyInDrawnOrder() {
        let drawn = ["b", "c", "a", "d"]
        #expect(TabStripDividers.visible(in: drawn, selected: nil, hovered: nil, dragged: nil, busy: ["d"])
            == [true, true, false])
        #expect(TabStripDividers.visible(in: drawn, selected: nil, hovered: nil, dragged: nil, busy: ["gone"])
            == [true, true, true])
    }
}
