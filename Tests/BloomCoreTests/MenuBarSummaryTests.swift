import Testing
@testable import BloomCore

@Suite("Menu bar summary")
struct MenuBarSummaryTests {
    @Test("says nothing at all when there is nothing to say")
    func quietWhenIdle() {
        #expect(MenuBarSummary.segments(waiting: 0, unread: 0).isEmpty)
    }

    @Test("shows a count only for the thing that has one")
    func dropsZeroes() {
        let waiting = MenuBarSummary.segments(waiting: 2, unread: 0)
        #expect(waiting.map(\.symbolName) == [MenuBarSummary.waitingSymbol])
        #expect(waiting.first?.count == 2)

        let unread = MenuBarSummary.segments(waiting: 0, unread: 5)
        #expect(unread.map(\.symbolName) == [MenuBarSummary.unreadSymbol])
        #expect(unread.first?.count == 5)
    }

    @Test("puts the thing that costs something before the thing that will keep")
    func ordersWaitingFirst() {
        let segments = MenuBarSummary.segments(waiting: 3, unread: 1)

        #expect(segments.count == 2)
        #expect(segments.map(\.symbolName) == [MenuBarSummary.waitingSymbol, MenuBarSummary.unreadSymbol])
        #expect(segments.map(\.count) == [3, 1])
    }

    /// The strip is two glyphs at most, and neither of them is the dot. A filled circle beside a
    /// filled hand at menu bar size is two dark blobs the owner could not tell apart, and the one
    /// he could not read was the count that costs money. A hand and an envelope are shapes.
    @Test("never draws the running dot in the strip")
    func noRunningSegment() {
        let symbols = MenuBarSummary.segments(waiting: 3, unread: 1).map(\.symbolName)

        #expect(!symbols.contains(MenuBarSummary.runningSymbol))
    }

    @Test("spells the glyphs out in words on hover")
    func tooltipExplainsTheGlyphs() {
        #expect(MenuBarSummary.tooltip(waiting: 1, unread: 0) == "1 agent waiting on you")
        #expect(MenuBarSummary.tooltip(waiting: 3, unread: 0) == "3 agents waiting on you")
        #expect(MenuBarSummary.tooltip(waiting: 0, unread: 1) == "1 unread result")
        #expect(MenuBarSummary.tooltip(waiting: 2, unread: 4) == "2 agents waiting on you, 4 unread results")
    }

    /// Not "No agents running", which is the menu's empty row. A bare strip says nothing about
    /// whether anything is running, and three agents mid turn would be listed in the menu the
    /// moment that hover was believed.
    @Test("a bare strip hovers as nothing needing a person")
    func tooltipWhenBare() {
        #expect(MenuBarSummary.tooltip(waiting: 0, unread: 0) == MenuBarSummary.idleTooltip)
        #expect(MenuBarSummary.tooltip(waiting: 0, unread: 0) != MenuBarSummary.emptyTitle)
    }
}
