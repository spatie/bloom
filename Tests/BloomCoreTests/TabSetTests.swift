import Foundation
import Testing
@testable import BloomCore

/// The strip is derived, so this is the whole of what decides what is in it.
@Suite("TabSet")
struct TabSetTests {
    private let one = SessionID("s1")
    private let two = SessionID("s2")

    @Test("conversations come first and tools after them")
    func twoRuns() {
        let entries = TabSet.entries(sessions: [one, two], tools: ["t1", "t2"])

        #expect(entries == [.chat(one), .chat(two), .tool("t1"), .tool("t2")])
    }

    @Test("each run keeps the order it was handed")
    func ordering() {
        let entries = TabSet.entries(sessions: [two, one], tools: ["t2", "t1"])

        #expect(entries == [.chat(two), .chat(one), .tool("t2"), .tool("t1")])
    }

    @Test("a workspace with nothing but tools opens on a tool")
    func toolsOnly() {
        #expect(TabSet.entries(sessions: [], tools: ["t1"]) == [.tool("t1")])
    }

    @Test("an empty workspace has an empty strip")
    func empty() {
        #expect(TabSet.entries(sessions: [], tools: []).isEmpty)
    }

    /// The tmux rule: a thing lives in exactly one pane of exactly one tab, so a conversation
    /// opened beside another one is a pane of that tab and not also a tab of its own.
    @Test("something claimed as a pane of another tab drops out of the strip")
    func claimed() {
        let entries = TabSet.entries(
            sessions: [one, two], tools: ["t1", "t2"], claimed: [.chat(two), .tool("t1")]
        )

        #expect(entries == [.chat(one), .tool("t2")])
    }

    @Test("filtering never reorders what is left")
    func filteringKeepsOrder() {
        let entries = TabSet.entries(
            sessions: [one, two], tools: ["t1", "t2", "t3"], claimed: [.chat(one), .tool("t2")]
        )

        #expect(entries == [.chat(two), .tool("t1"), .tool("t3")])
    }

    /// A tab that claimed itself would drop out of the strip it roots, which is why the caller is
    /// handed the claimed set with the root already taken out.
    @Test("a tab's own root is not claimed, even when the same chat is in two of its panes")
    func rootIsNeverClaimed() throws {
        var layout = SplitLayout(pane: "p1")
        layout.split("p1", axis: .horizontal, into: "p2")
        let stored = StoredPaneArrangement(
            layout: try #require(layout.encoded),
            contents: ["p1": .chat(one), "p2": .chat(one)]
        )

        let claimed = stored.claimedContents(root: .chat(one))

        #expect(claimed.isEmpty)
        #expect(TabSet.entries(sessions: [one], tools: [], claimed: claimed) == [.chat(one)])
    }

    @Test("everything but the root is claimed")
    func claimedContents() throws {
        var layout = SplitLayout(pane: "p1")
        layout.split("p1", axis: .horizontal, into: "p2")
        layout.split("p2", axis: .vertical, into: "p3")
        let stored = StoredPaneArrangement(
            layout: try #require(layout.encoded),
            contents: ["p1": .chat(one), "p2": .chat(two), "p3": .tool("t1")]
        )

        #expect(stored.claimedContents(root: .chat(one)) == [.chat(two), .tool("t1")])
    }
}
