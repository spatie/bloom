import Foundation
import Testing
@testable import BloomCore

/// The orphan sweep kills every tmux session whose pane id it cannot enumerate, so this is the
/// difference between a dev server that survives a quit and one that a launch nobody asked
/// anything of quietly killed. Commit 2e3d6e3 is the lesson; this suite is it applied in advance.
@Suite("TerminalPaneCensus")
struct TerminalPaneCensusTests {
    private let workspace = WorkspaceID("w1")

    /// A domain of its own per test. The owner's real domain is never opened: he is using the app
    /// while this runs, with live shells in it.
    private func domain() -> (name: String, defaults: UserDefaults) {
        let name = "bloom.test.tabs.\(UUID().uuidString)"
        return (name, UserDefaults(suiteName: name)!)
    }

    private func clean(_ name: String) {
        UserDefaults.standard.removePersistentDomain(forName: name)
    }

    /// Written by hand in the shape `CenterTabStore` writes, because `CenterTab` is a view layer
    /// type the core suite cannot see. That is the point: this pins the bytes rather than a type.
    private func tabList(_ defaults: UserDefaults) {
        let json = #"""
        [{"id":"t1","workspaceID":"w1","kind":"terminal","title":"Terminal","url":"","path":""},
         {"id":"t2","workspaceID":"w1","kind":"browser","title":"Browser","url":"http://x","path":""},
         {"id":"t3","workspaceID":"w1","kind":"terminal","title":"Server","url":"","path":""}]
        """#
        defaults.set(json.data(using: .utf8), forKey: "center.tabs.w1")
    }

    // MARK: - Reading

    @Test("only terminal tabs are counted")
    func terminalTabsOnly() {
        let (name, defaults) = domain()
        defer { clean(name) }
        tabList(defaults)

        #expect(TerminalPaneCensus.terminalTabs(of: workspace, in: defaults) == ["t1", "t3"])
    }

    @Test("a workspace with no tab list names no panes")
    func noTabs() {
        let (name, defaults) = domain()
        defer { clean(name) }

        #expect(TerminalPaneCensus.terminalTabs(of: workspace, in: defaults).isEmpty)
        #expect(TerminalPaneCensus.livePanes(of: [workspace], in: defaults).isEmpty)
    }

    /// A tab nobody split is one pane carrying the tab's own id, which is what keeps a shell forked
    /// before splitting existed exactly where it was.
    @Test("an unsplit tab is one pane named after the tab")
    func unsplitTab() {
        let (name, defaults) = domain()
        defer { clean(name) }

        #expect(TerminalPaneCensus.panes(ofTab: "t1", in: defaults) == ["t1"])
    }

    @Test("a split tab names every pane of its tree")
    func splitTab() throws {
        let (name, defaults) = domain()
        defer { clean(name) }
        var layout = SplitLayout(pane: "t1")
        layout.split("t1", axis: .horizontal, into: "x1")
        layout.split("x1", axis: .vertical, into: "x2")
        let value = try #require(layout.encoded)
        defaults.set(value, forKey: "terminal.split.t1")

        #expect(TerminalPaneCensus.panes(ofTab: "t1", in: defaults) == ["t1", "x1", "x2"])
    }

    @Test("the live set is every terminal tab of every workspace, expanded")
    func livePanes() throws {
        let (name, defaults) = domain()
        defer { clean(name) }
        tabList(defaults)
        var layout = SplitLayout(pane: "t1")
        layout.split("t1", axis: .horizontal, into: "x1")
        let value = try #require(layout.encoded)
        defaults.set(value, forKey: "terminal.split.t1")

        #expect(TerminalPaneCensus.livePanes(of: [workspace], in: defaults) == ["t1", "x1", "t3"])
    }

    // MARK: - The invariant

    /// **The one that matters.** Phase A re-files a workspace's carve under a tab and touches
    /// nothing else, so the set of pane ids the sweep can reach has to come out of it byte for
    /// byte the same. If the migration and the enumeration ever disagree, the owner loses running
    /// shells and there is no way to get one back.
    @Test("the panes the sweep can reach are unchanged by the migration")
    func invariantUnderMigration() throws {
        let (name, defaults) = domain()
        defer { clean(name) }
        tabList(defaults)

        var terminal = SplitLayout(pane: "t1")
        terminal.split("t1", axis: .horizontal, into: "x1")
        let shells = try #require(terminal.encoded)
        defaults.set(shells, forKey: "terminal.split.t1")

        // A carve holding a conversation, a terminal tab, the same terminal tab again and a pane
        // pointing at nothing: every rule the migration has, in one workspace.
        var carve = SplitLayout(pane: "c1")
        carve.split("c1", axis: .horizontal, into: "c2")
        carve.split("c2", axis: .vertical, into: "c3")
        carve.split("c3", axis: .horizontal, into: "c4")
        let old = StoredPaneArrangement(
            layout: try #require(carve.encoded),
            contents: ["c1": .chat(SessionID("s1")), "c2": .tool("t1"), "c4": .tool("t1")]
        )
        let panes = try #require(old.encoded)
        defaults.set(panes, forKey: "center.panes.w1")

        let before = TerminalPaneCensus.livePanes(of: [workspace], in: defaults)
        #expect(before == ["t1", "x1", "t3"])

        let migrated = TabMigration.migrateAll(in: defaults)

        #expect(migrated.count == 1)
        #expect(TerminalPaneCensus.livePanes(of: [workspace], in: defaults) == before)
    }

    /// The other half of the same argument, and the stronger one: the migration is not merely
    /// harmless to the sweep, it never writes a key the sweep reads.
    @Test("the migration touches no key the sweep reads")
    func touchesNoTerminalKey() throws {
        let (name, defaults) = domain()
        defer { clean(name) }
        tabList(defaults)
        var terminal = SplitLayout(pane: "t1")
        terminal.split("t1", axis: .horizontal, into: "x1")
        let shells = try #require(terminal.encoded)
        defaults.set(shells, forKey: "terminal.split.t1")

        var carve = SplitLayout(pane: "c1")
        carve.split("c1", axis: .horizontal, into: "c2")
        let old = StoredPaneArrangement(
            layout: try #require(carve.encoded),
            contents: ["c1": .chat(SessionID("s1")), "c2": .tool("t1")]
        )
        let panes = try #require(old.encoded)
        defaults.set(panes, forKey: "center.panes.w1")

        let before = try #require(UserDefaults.standard.persistentDomain(forName: name))
        TabMigration.migrateAll(in: defaults)
        let after = try #require(UserDefaults.standard.persistentDomain(forName: name))

        #expect(Set(before.keys) == ["center.tabs.w1", "terminal.split.t1", "center.panes.w1"])
        #expect(Set(after.keys) == ["center.tabs.w1", "terminal.split.t1", "center.tab.s1"])
        #expect(after["center.tabs.w1"] as? Data == before["center.tabs.w1"] as? Data)
        #expect(after["terminal.split.t1"] as? String == before["terminal.split.t1"] as? String)
    }

    /// A tool that is in the carve is in the tab, whichever of its panes went. The set of ids is
    /// what the sweep compares against, so collapsing a duplicate must not lose one.
    @Test("every tool the carve pointed at is still pointed at afterwards")
    func toolsSurvive() throws {
        var carve = SplitLayout(pane: "c1")
        carve.split("c1", axis: .horizontal, into: "c2")
        carve.split("c2", axis: .vertical, into: "c3")
        let old = StoredPaneArrangement(
            layout: try #require(carve.encoded),
            contents: ["c1": .tool("t1"), "c2": .chat(SessionID("s1")), "c3": .tool("t1")]
        )

        let tab = try #require(TabMigration.invert(old))

        #expect(Set(old.contents.values.map(\.id)) == Set(tab.stored.contents.values.map(\.id)))
    }
}
