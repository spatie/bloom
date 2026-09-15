import Testing
@testable import BloomCore

/// The busy signal used to run along the strip's rule and vanished with the strip. These are the
/// two places it went instead, the column's top edge and the tabs themselves, and the rule that it
/// is only ever in one of them.
@Suite("Where the busy signal is drawn")
struct BusySignalPlacementTests {
    private typealias Placement = BusySignalPlacement<String>

    @Test("a lone tab with an agent running sweeps the column's top edge")
    func loneBusyTab() {
        let placement = Placement.resolve(
            isStripShown: false, tabs: ["chat"], selected: "chat", isRunning: { $0 == "chat" }
        )
        #expect(placement == .columnTop)
        #expect(placement.showsColumnTop)
        #expect(!placement.showsInTab("chat"))
    }

    @Test("a lone idle tab shows nothing")
    func loneIdleTab() {
        let placement = Placement.resolve(
            isStripShown: false, tabs: ["chat"], selected: "chat", isRunning: { _ in false }
        )
        #expect(placement == .none)
        #expect(!placement.showsColumnTop)
    }

    /// The column shows one tab, so a turn running in a pane of that tab is running in what is on
    /// screen, even though the tab is filed under the other pane.
    @Test("with no strip, a turn in any pane of the visible tab counts")
    func splitWithNoStrip() {
        let placement = Placement.resolve(
            isStripShown: false, tabs: ["chat"], selected: "chat",
            panes: { $0 == "chat" ? ["chat", "second"] : [$0] },
            isRunning: { $0 == "second" }
        )
        #expect(placement == .columnTop)
    }

    @Test("a selection that has not resolved falls back to the only tab")
    func unresolvedSelection() {
        let placement = Placement.resolve(
            isStripShown: false, tabs: ["chat"], selected: nil, isRunning: { _ in true }
        )
        #expect(placement == .columnTop)
        #expect(Placement.resolve(
            isStripShown: false, tabs: ["a", "b"], selected: nil, isRunning: { _ in true }
        ) == .none)
        #expect(Placement.resolve(
            isStripShown: false, tabs: [], selected: nil, isRunning: { _ in true }
        ) == .none)
    }

    /// The whole reason for a per tab answer: two busy tabs sweep, an idle tab does not, and the
    /// column's edge stays dark because the tabs already say it.
    @Test("with a strip, each busy tab sweeps and the column's edge stays dark")
    func perTab() {
        let placement = Placement.resolve(
            isStripShown: true, tabs: ["a", "b", "c"], selected: "b",
            isRunning: { $0 != "b" }
        )
        #expect(placement == .tabs(["a", "c"]))
        #expect(!placement.showsColumnTop)
        #expect(placement.showsInTab("a"))
        #expect(!placement.showsInTab("b"))
        #expect(placement.showsInTab("c"))
    }

    @Test("a split tab in the strip is busy when any of its panes is")
    func splitTabInStrip() {
        let placement = Placement.resolve(
            isStripShown: true, tabs: ["a", "b"], selected: "a",
            panes: { $0 == "a" ? ["a", "absorbed"] : [$0] },
            isRunning: { $0 == "absorbed" }
        )
        #expect(placement == .tabs(["a"]))
    }

    @Test("a strip with nothing running is none, never an empty set")
    func idleStrip() {
        let placement = Placement.resolve(
            isStripShown: true, tabs: ["a", "b"], selected: "a", isRunning: { _ in false }
        )
        #expect(placement == .none)
    }

    /// A rename keeps the strip up on a single tab. The signal follows the strip rather than the
    /// tab count, so it moves into the tab while the field is open and never shows twice.
    @Test("the strip decides, not the tab count")
    func followsTheStrip() {
        let shown = Placement.resolve(
            isStripShown: true, tabs: ["chat"], selected: "chat", isRunning: { _ in true }
        )
        #expect(shown == .tabs(["chat"]))
        #expect(!shown.showsColumnTop)
    }
}
