import Testing
@testable import BloomCore

@Suite("Menu bar summary")
struct MenuBarSummaryTests {
    @Test("says nothing at all when there is nothing to say")
    func quietWhenIdle() {
        #expect(MenuBarSummary.segments(running: 0, unread: 0).isEmpty)
    }

    @Test("shows a count only for the thing that has one")
    func dropsZeroes() {
        let running = MenuBarSummary.segments(running: 2, unread: 0)
        #expect(running.map(\.symbolName) == [MenuBarSummary.runningSymbol])
        #expect(running.first?.count == 2)

        let unread = MenuBarSummary.segments(running: 0, unread: 5)
        #expect(unread.map(\.symbolName) == [MenuBarSummary.unreadSymbol])
        #expect(unread.first?.count == 5)
    }

    @Test("puts the thing still moving before the thing that will wait")
    func ordersRunningFirst() {
        let segments = MenuBarSummary.segments(running: 3, unread: 1)

        #expect(segments.count == 2)
        #expect(segments.map(\.symbolName) == [MenuBarSummary.runningSymbol, MenuBarSummary.unreadSymbol])
        #expect(segments.map(\.count) == [3, 1])
    }

    @Test("spells the glyphs out in words on hover")
    func tooltipExplainsTheGlyphs() {
        #expect(MenuBarSummary.tooltip(running: 1, unread: 0) == "1 agent running")
        #expect(MenuBarSummary.tooltip(running: 3, unread: 0) == "3 agents running")
        #expect(MenuBarSummary.tooltip(running: 0, unread: 1) == "1 unread result")
        #expect(MenuBarSummary.tooltip(running: 2, unread: 4) == "2 agents running, 4 unread results")
        #expect(MenuBarSummary.tooltip(running: 0, unread: 0) == MenuBarSummary.emptyTitle)
    }
}
