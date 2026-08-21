import Foundation
import Testing
@testable import BloomCore

/// Closing a pane is about arrangement and never about lifecycle, so every case here is checked
/// twice: what the tab becomes, and that the thing the pane was holding is still named somewhere a
/// caller can find it. A tab that dissolved when it should have been re-filed, or a shell dropped
/// on the floor because its pane went, are both silent.
@Suite("TabSurgery")
struct TabSurgeryTests {
    private let chat = SessionID("s1")
    private let other = SessionID("s2")

    /// Three panes, two splits, one moved divider. `p1` beside a stack of `p2` over `p3`.
    private func nested() -> SplitLayout {
        var layout = SplitLayout(pane: "p1")
        layout.split("p1", axis: .horizontal, into: "p2")
        layout.split("p2", axis: .vertical, into: "p3")
        layout.setRatio(0.7, at: [])
        layout.setFocus("p1")
        return layout
    }

    private func arrangement(
        _ layout: SplitLayout, _ contents: [String: PaneContent]
    ) throws -> StoredPaneArrangement {
        StoredPaneArrangement(layout: try #require(layout.encoded), contents: contents)
    }

    private func pair() throws -> StoredPaneArrangement {
        var layout = SplitLayout(pane: "p1")
        layout.split("p1", axis: .horizontal, into: "p2")
        return try arrangement(layout, ["p1": .chat(chat), "p2": .tool("t1")])
    }

    // MARK: - Closing a pane

    @Test("closing a pane of a tab with more than two leaves a smaller tab")
    func closeLeavesTab() throws {
        let stored = try arrangement(
            nested(), ["p1": .chat(chat), "p2": .tool("t1"), "p3": .chat(other)]
        )

        let outcome = TabSurgery.closePane("p2", in: stored, root: .chat(chat))

        guard case .updated(let root, let result) = outcome else {
            Issue.record("expected the tab to survive, got \(outcome)")
            return
        }
        #expect(root == .chat(chat))
        #expect(SplitLayout(encoded: result.layout)?.panes == ["p1", "p3"])
        #expect(result.contents == ["p1": .chat(chat), "p3": .chat(other)])
    }

    /// The point of the whole thing. The terminal is not stopped and not forgotten: it stops being
    /// claimed, and `TabSet.entries` hands it back to the strip as a tab of its own.
    @Test("closing the last pane beside the root dissolves the tab and ejects what it held")
    func closeEjects() throws {
        let outcome = TabSurgery.closePane("p2", in: try pair(), root: .chat(chat))

        #expect(outcome == .dissolved(remaining: .chat(chat)))
    }

    @Test("closing the root's own pane re-files the tab under what is left")
    func closeRefiles() throws {
        let stored = try arrangement(
            nested(), ["p1": .chat(chat), "p2": .tool("t1"), "p3": .chat(other)]
        )

        let outcome = TabSurgery.closePane("p1", in: stored, root: .chat(chat))

        guard case .updated(let root, let result) = outcome else {
            Issue.record("expected the tab to survive, got \(outcome)")
            return
        }
        // The other conversation rather than the terminal, even though the terminal comes first in
        // pane order: a chat root files the tab in the strip's conversation run.
        #expect(root == .chat(other))
        #expect(SplitLayout(encoded: result.layout)?.panes == ["p2", "p3"])
    }

    @Test("a tab of nothing but tools is re-filed under the first of them")
    func refilesOntoTool() throws {
        let stored = try arrangement(
            nested(), ["p1": .chat(chat), "p2": .tool("t1"), "p3": .tool("t2")]
        )

        let outcome = TabSurgery.closePane("p1", in: stored, root: .chat(chat))

        guard case .updated(let root, _) = outcome else {
            Issue.record("expected the tab to survive, got \(outcome)")
            return
        }
        #expect(root == .tool("t1"))
    }

    @Test("the tree, the ratios and the focus survive a close")
    func closeKeepsShape() throws {
        var layout = nested()
        layout.setFocus("p3")
        let stored = try arrangement(
            layout, ["p1": .chat(chat), "p2": .tool("t1"), "p3": .chat(other)]
        )

        let outcome = TabSurgery.closePane("p2", in: stored, root: .chat(chat))

        guard case .updated(_, let result) = outcome else {
            Issue.record("expected the tab to survive, got \(outcome)")
            return
        }
        let tree = try #require(SplitLayout(encoded: result.layout))
        #expect(tree.focus == "p3")
        #expect(tree.ratio(at: []) == 0.7)
    }

    /// `SplitLayout.close` moves the focus to whatever grew into the closed pane's space, and this
    /// must not undo that.
    @Test("closing the focused pane leaves the focus on a pane that exists")
    func closeMovesFocus() throws {
        var layout = nested()
        layout.setFocus("p2")
        let stored = try arrangement(
            layout, ["p1": .chat(chat), "p2": .tool("t1"), "p3": .chat(other)]
        )

        let outcome = TabSurgery.closePane("p2", in: stored, root: .chat(chat))

        guard case .updated(_, let result) = outcome else {
            Issue.record("expected the tab to survive, got \(outcome)")
            return
        }
        let tree = try #require(SplitLayout(encoded: result.layout))
        #expect(tree.panes.contains(tree.focus))
        #expect(tree.focus == "p3")
    }

    @Test("a pane this tab does not have changes nothing")
    func closeUnknownPane() throws {
        #expect(TabSurgery.closePane("nope", in: try pair(), root: .chat(chat)) == .unchanged)
    }

    /// A column with one pane cannot be closed. The strip's own close buttons are how a workspace
    /// loses a conversation or a tool.
    @Test("the only pane of a tab cannot be closed")
    func closeLastPane() throws {
        let stored = try arrangement(SplitLayout(pane: "p1"), ["p1": .chat(chat)])

        #expect(TabSurgery.closePane("p1", in: stored, root: .chat(chat)) == .unchanged)
    }

    // MARK: - Removing a content

    @Test("a closed tool tab takes its pane and leaves the rest of the tab standing")
    func removeLeavesTab() throws {
        let stored = try arrangement(
            nested(), ["p1": .chat(chat), "p2": .tool("t1"), "p3": .chat(other)]
        )

        let outcome = TabSurgery.remove(.tool("t1"), from: stored, root: .chat(chat))

        guard case .updated(let root, let result) = outcome else {
            Issue.record("expected the tab to survive, got \(outcome)")
            return
        }
        #expect(root == .chat(chat))
        #expect(SplitLayout(encoded: result.layout)?.panes == ["p1", "p3"])
        #expect(result.contents["p2"] == nil)
    }

    /// One chat renders happily in two panes of one tab, which `TabSet` allows on purpose, so
    /// archiving it has to take both of them and not just the first.
    @Test("an archived conversation takes every pane that was showing it")
    func removeTakesEveryPane() throws {
        var layout = nested()
        layout.setFocus("p1")
        let stored = try arrangement(
            layout, ["p1": .chat(chat), "p2": .chat(other), "p3": .chat(other)]
        )

        let outcome = TabSurgery.remove(.chat(other), from: stored, root: .chat(chat))

        #expect(outcome == .dissolved(remaining: .chat(chat)))
    }

    @Test("archiving the conversation a tab is named after re-files it under what is left")
    func removeRefiles() throws {
        let stored = try arrangement(
            nested(), ["p1": .chat(chat), "p2": .tool("t1"), "p3": .tool("t2")]
        )

        let outcome = TabSurgery.remove(.chat(chat), from: stored, root: .chat(chat))

        guard case .updated(let root, let result) = outcome else {
            Issue.record("expected the tab to survive, got \(outcome)")
            return
        }
        #expect(root == .tool("t1"))
        #expect(SplitLayout(encoded: result.layout)?.panes == ["p2", "p3"])
    }

    /// A tab that was two views of one conversation goes when the conversation does, rather than
    /// being left standing on a pointer to nothing.
    @Test("a tab holding nothing but the dead content dissolves")
    func removeDissolvesEntirely() throws {
        var layout = SplitLayout(pane: "p1")
        layout.split("p1", axis: .vertical, into: "p2")
        let stored = try arrangement(layout, ["p1": .chat(chat), "p2": .chat(chat)])

        let outcome = TabSurgery.remove(.chat(chat), from: stored, root: .chat(chat))

        #expect(outcome == .dissolved(remaining: .chat(chat)))
    }

    @Test("a content this tab was not holding changes nothing")
    func removeUnknownContent() throws {
        #expect(TabSurgery.remove(.tool("t9"), from: try pair(), root: .chat(chat)) == .unchanged)
    }

    // MARK: - Settling a tab that was rearranged rather than shrunk

    /// Pointing the root's last pane at something else takes the root out of the tab just as
    /// surely as closing that pane would, so it has to be answered the same way.
    @Test("a tab whose root has been pointed away from is re-filed")
    func settleRefiles() throws {
        var stored = try pair()
        stored.contents["p1"] = .chat(other)

        let outcome = TabSurgery.settle(stored, root: .chat(chat))

        guard case .updated(let root, let result) = outcome else {
            Issue.record("expected the tab to survive, got \(outcome)")
            return
        }
        #expect(root == .chat(other))
        #expect(result.contents == ["p1": .chat(other), "p2": .tool("t1")])
    }

    @Test("a tab still holding its root settles under the same name")
    func settleKeepsRoot() throws {
        let outcome = TabSurgery.settle(try pair(), root: .chat(chat))

        #expect(outcome == .updated(root: .chat(chat), stored: try pair()))
    }

    // MARK: - Replayability

    /// The store writes the new key before it deletes the old one, so a crash between those two
    /// lines leaves the same input to be operated on again next launch. Twice must mean once.
    @Test("running the same removal twice writes the same record")
    func deterministic() throws {
        let stored = try arrangement(
            nested(), ["p1": .chat(chat), "p2": .tool("t1"), "p3": .chat(other)]
        )

        let first = TabSurgery.remove(.tool("t1"), from: stored, root: .chat(chat))
        guard case .updated(let root, let result) = first else {
            Issue.record("expected the tab to survive, got \(first)")
            return
        }

        #expect(TabSurgery.remove(.tool("t1"), from: result, root: root) == .unchanged)
        #expect(result.encoded == TabSurgery.remove(.tool("t1"), from: stored, root: .chat(chat)).storedRecord?.encoded)
    }
}

private extension TabSurgery.Outcome {
    var storedRecord: StoredPaneArrangement? {
        guard case .updated(_, let stored) = self else { return nil }
        return stored
    }
}
