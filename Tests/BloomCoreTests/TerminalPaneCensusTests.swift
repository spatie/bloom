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

    /// No key at all is a fact, not a silence: this workspace has never had a centre terminal in
    /// it. It answers with none rather than with doubt, because doubt here would mean the sweep
    /// never collected anything on a machine where most workspaces have no centre terminal.
    @Test("a workspace with no tab list names no panes and is not in doubt")
    func noTabs() {
        let (name, defaults) = domain()
        defer { clean(name) }

        #expect(TerminalPaneCensus.terminalTabs(of: workspace, in: defaults) == [])
        #expect(TerminalPaneCensus.census(of: [workspace], in: defaults) == .init())
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

        #expect(TerminalPaneCensus.census(of: [workspace], in: defaults).panes == ["t1", "x1", "t3"])
    }

    // MARK: - The wire contract

    /// **The half of this that a renamed field breaks.**
    ///
    /// The core suite depends on `BloomCore` alone (read `Package.swift`), so `CenterTab` is out of
    /// reach from here and a hand written literal is the only way to hold its shape still. That is
    /// not a workaround, it is the stronger pin: what the census has to read is the bytes already
    /// on the owner's disk, not what a type says about them today. Rename a coding key, or change
    /// what `CenterTab.Kind.terminal` encodes as, and this fails, which is the warning that a
    /// migration is owed. Without it the same rename is silent, and silent here is the empty set,
    /// which is the answer that kills rather than the one that spares.
    @Test("the stored tab record is read field for field as CenterTab writes it")
    func wireContract() {
        let (name, defaults) = domain()
        defer { clean(name) }

        // Byte for byte what `CenterTabStore.persist` writes today, and then, as the second
        // element, a record from before `url` and `path` were added. Both name their pane: this
        // reads two fields rather than the whole tab exactly so an older record still counts.
        let current = #"{"id":"t1","workspaceID":"w1","kind":"terminal","title":"Terminal","url":"","path":""}"#
        let legacy = #"{"id":"t2","workspaceID":"w1","kind":"terminal","title":"Server"}"#
        defaults.set(Data("[\(current),\(legacy)]".utf8), forKey: "center.tabs.w1")

        #expect(TerminalPaneCensus.terminalTabs(of: workspace, in: defaults) == ["t1", "t2"])
    }

    /// The keys themselves, written out rather than built, because the literal is the contract.
    /// `TabDefaults` is where the census and the two view stores now agree on them; before that
    /// each said it separately and a drift on one side alone would have the sweep see no panes.
    ///
    /// The last line is the near miss `TabDefaults.tabPrefix` warns about: `center.tab.` and
    /// `center.tabs.` differ only in where the dot falls, and a scan for the singular that
    /// swallowed the plural would read a tab list as an arrangement and throw it away.
    @Test("the keys the sweep reads are the keys the stores write")
    func keysArePinned() {
        #expect(TabDefaults.tabListKey(workspace) == "center.tabs.w1")
        #expect(TabDefaults.splitKey("t1") == "terminal.split.t1")
        #expect(!TabDefaults.tabListKey(workspace).hasPrefix(TabDefaults.tabPrefix))
    }

    // MARK: - Doubt

    /// **The one that decides whether a mistake costs shells.**
    ///
    /// A tab list that is there and will not decode is not the same fact as a workspace with no
    /// terminals in it, and the difference is what `TerminalPersistence.sessions()` already keeps
    /// by returning nil rather than an empty list. Flattened into a set, unreadable bytes read as
    /// "nothing here is reachable" and `TmuxSessions.orphans` kills every session the workspace
    /// owns. Reported as doubt, the sweep leaves them alone and a later launch can collect them.
    @Test("a tab list that will not decode is doubt, not an answer")
    func unreadableTabList() {
        let (name, defaults) = domain()
        defer { clean(name) }
        defaults.set(Data("not json".utf8), forKey: "center.tabs.w1")

        #expect(TerminalPaneCensus.terminalTabs(of: workspace, in: defaults) == nil)
        #expect(TerminalPaneCensus.census(of: [workspace], in: defaults)
            == .init(doubtful: [workspace]))
    }

    /// The same argument one level down. A tab whose tree will not decode has panes with ids
    /// nothing here can name, so answering with the tab's own id alone would name one pane and
    /// leave every pane split off it looking unreachable.
    @Test("a split tree that will not decode is doubt, not one pane")
    func unreadableSplitTree() {
        let (name, defaults) = domain()
        defer { clean(name) }
        tabList(defaults)
        defaults.set("not a layout", forKey: "terminal.split.t1")

        #expect(TerminalPaneCensus.panes(ofTab: "t1", in: defaults) == nil)

        // t3 still read cleanly, so its pane is named. The workspace is in doubt all the same,
        // and the sweep spares by workspace, so t3's session is spared with t1's.
        #expect(TerminalPaneCensus.census(of: [workspace], in: defaults)
            == .init(panes: ["t3"], doubtful: [workspace]))
    }

    /// A kind that is not `terminal` is not doubt. The census reads the whole record, learns that
    /// this tab holds no shell, and says so; only bytes it could not read at all are doubt.
    @Test("an unknown tab kind names no pane and raises no doubt")
    func unknownKind() {
        let (name, defaults) = domain()
        defer { clean(name) }
        let json = #"[{"id":"t9","workspaceID":"w1","kind":"canvas","title":"Canvas"}]"#
        defaults.set(Data(json.utf8), forKey: "center.tabs.w1")

        #expect(TerminalPaneCensus.census(of: [workspace], in: defaults) == .init())
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

        let before = TerminalPaneCensus.census(of: [workspace], in: defaults)
        #expect(before == .init(panes: ["t1", "x1", "t3"]))

        let migrated = TabMigration.migrateAll(in: defaults)

        #expect(migrated.count == 1)
        #expect(TerminalPaneCensus.census(of: [workspace], in: defaults) == before)
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
