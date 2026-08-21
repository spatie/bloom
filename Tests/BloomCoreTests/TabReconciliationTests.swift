import Foundation
import Testing
@testable import BloomCore

/// The reconcile judgement, and above all the two cases that look identical to a set and are not:
/// a list that was read and is empty, and a list nobody has read yet.
///
/// Every case is checked through `TabSurgery.remove` as well as against the named contents, because
/// what this decides is not a report. It is what gets destroyed: the store forgets each content it
/// is handed, which dissolves a two pane tab and deletes its `center.tab.*` key.
@Suite("TabReconciliation")
struct TabReconciliationTests {
    private let chat = SessionID("s1")
    private let second = SessionID("s2")

    private func arrangement(
        _ layout: SplitLayout, _ contents: [String: PaneContent]
    ) throws -> StoredPaneArrangement {
        StoredPaneArrangement(layout: try #require(layout.encoded), contents: contents)
    }

    /// A terminal with a conversation beside it: a tab rooted on the tool, which is the only shape
    /// the empty session list ever reached. A chat rooted tab is skipped because its root is not in
    /// the live set either.
    private func toolRootedPair() throws -> (root: PaneContent, stored: StoredPaneArrangement) {
        var layout = SplitLayout(pane: "t1")
        _ = layout.split("t1", axis: .horizontal, into: "p2")
        return (.tool("t1"), try arrangement(layout, ["t1": .tool("t1"), "p2": .chat(chat)]))
    }

    /// A conversation with a terminal beside it, filed under the chat.
    private func chatRootedPair() throws -> (root: PaneContent, stored: StoredPaneArrangement) {
        var layout = SplitLayout(pane: "c1")
        _ = layout.split("c1", axis: .horizontal, into: "p2")
        return (.chat(chat), try arrangement(layout, ["c1": .chat(chat), "p2": .tool("t1")]))
    }

    /// What the store does with what it is told, in one step.
    private func outcomes(
        of tab: (root: PaneContent, stored: StoredPaneArrangement),
        sessions: [SessionID]?,
        tools: [String]?
    ) -> [TabSurgery.Outcome] {
        TabReconciliation.dead(in: [tab.root: tab.stored], sessions: sessions, tools: tools)
            .map { TabSurgery.remove($0, from: tab.stored, root: tab.root) }
    }

    // MARK: - A list that was read

    @Test("a session archived in another launch is forgotten")
    func archivedSessionIsDead() throws {
        let tab = try toolRootedPair()
        let dead = TabReconciliation.dead(
            in: [tab.root: tab.stored], sessions: [], tools: ["t1"]
        )
        #expect(dead == [.chat(chat)])
        #expect(outcomes(of: tab, sessions: [], tools: ["t1"]) == [.dissolved(remaining: .tool("t1"))])
    }

    @Test("a tool tab closed in another launch is forgotten")
    func closedToolIsDead() throws {
        let tab = try chatRootedPair()
        #expect(TabReconciliation.dead(
            in: [tab.root: tab.stored], sessions: [chat], tools: []
        ) == [.tool("t1")])
    }

    @Test("a pointer to something still there is left alone")
    func liveContentSurvives() throws {
        let tab = try toolRootedPair()
        #expect(TabReconciliation.dead(
            in: [tab.root: tab.stored], sessions: [chat], tools: ["t1"]
        ).isEmpty)
    }

    // MARK: - A list nobody has read yet

    /// The bug. The strip's task called this while `WorkspaceModel` was still on the `Store` actor,
    /// so the tool list was real and the session list was empty, and the split dissolved.
    @Test("a session list that has not been read yet condemns nothing")
    func unreadSessionListCondemnsNothing() throws {
        let tab = try toolRootedPair()
        #expect(TabReconciliation.dead(
            in: [tab.root: tab.stored], sessions: nil, tools: ["t1"]
        ).isEmpty)
        #expect(outcomes(of: tab, sessions: nil, tools: ["t1"]) == [])
    }

    /// The same trap the other way up, which is what a caller reconciling from the session load
    /// rather than from the strip would have walked into: real chats, no tool list, every terminal
    /// pane of a chat rooted tab dead.
    @Test("a tool list that has not been read yet condemns nothing")
    func unreadToolListCondemnsNothing() throws {
        let tab = try chatRootedPair()
        #expect(TabReconciliation.dead(
            in: [tab.root: tab.stored], sessions: [chat], tools: nil
        ).isEmpty)
        #expect(outcomes(of: tab, sessions: [chat], tools: nil) == [])
    }

    @Test("neither list read condemns nothing")
    func nothingReadCondemnsNothing() throws {
        let tab = try toolRootedPair()
        #expect(TabReconciliation.dead(
            in: [tab.root: tab.stored], sessions: nil, tools: nil
        ).isEmpty)
    }

    /// Doubt about one kind does not stop the other kind healing: the tool list is real here, so a
    /// pane pointing at a tool that has gone is still named while the chats are spared.
    @Test("an unread session list still lets a dead tool pointer go")
    func doubtIsPerKind() throws {
        var layout = SplitLayout(pane: "t1")
        _ = layout.split("t1", axis: .horizontal, into: "p2")
        _ = layout.split("p2", axis: .vertical, into: "p3")
        let stored = try arrangement(
            layout, ["t1": .tool("t1"), "p2": .chat(chat), "p3": .tool("gone")]
        )
        #expect(TabReconciliation.dead(
            in: [.tool("t1"): stored], sessions: nil, tools: ["t1"]
        ) == [.tool("gone")])
    }

    // MARK: - Which tabs are judged at all

    @Test("another workspace's tab is not judged against this workspace's lists")
    func otherWorkspacesTabIsUntouched() throws {
        let mine = try toolRootedPair()
        var layout = SplitLayout(pane: "t9")
        _ = layout.split("t9", axis: .horizontal, into: "p2")
        let theirs = try arrangement(layout, ["t9": .tool("t9"), "p2": .chat(second)])

        #expect(TabReconciliation.dead(
            in: [mine.root: mine.stored, .tool("t9"): theirs],
            sessions: [chat], tools: ["t1"]
        ).isEmpty)
    }

    @Test("a record whose layout will not decode names nothing")
    func undecodableLayoutNamesNothing() {
        let stored = StoredPaneArrangement(
            layout: "not a layout", contents: ["t1": .tool("t1"), "p2": .chat(chat)]
        )
        #expect(TabReconciliation.dead(
            in: [.tool("t1"): stored], sessions: [], tools: ["t1"]
        ).isEmpty)
    }

    @Test("two dead pointers are named in the same order every launch")
    func deadPointersAreSorted() throws {
        var layout = SplitLayout(pane: "t1")
        _ = layout.split("t1", axis: .horizontal, into: "p2")
        _ = layout.split("p2", axis: .vertical, into: "p3")
        let stored = try arrangement(
            layout, ["t1": .tool("t1"), "p2": .chat(SessionID("b")), "p3": .chat(SessionID("a"))]
        )
        #expect(TabReconciliation.dead(
            in: [.tool("t1"): stored], sessions: [], tools: ["t1"]
        ) == [.chat(SessionID("a")), .chat(SessionID("b"))])
    }
}
