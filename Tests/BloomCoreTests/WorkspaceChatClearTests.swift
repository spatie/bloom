import Foundation
import Testing
@testable import BloomCore

@Suite("Workspace chat clear", .scratchDirectory)
struct WorkspaceChatClearTests {
    @Test func replacesTheTabWithEmptyContextAndPreservesHistory() async throws {
        let store = try makeTestStore("workspace-clear")
        let repo = try await store.upsert(Repo(name: "r", path: TestScratch.unique("repo")))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "w", branch: "feature", path: TestScratch.unique("worktree"), baseBranch: "main"
        ))
        var original = Session(workspaceID: workspace.id, title: "Current chat", sortOrder: 0)
        original.agentSessionID = "old-context"
        original.contextTokens = 1000
        let first = try await store.upsert(original)
        let second = try await store.upsert(Session(workspaceID: workspace.id, title: "Neighbour", sortOrder: 1))
        try await store.appendNext(sessionID: first.id, kind: .user, payload: Data("keep history".utf8))
        try await store.saveDraft(sessionID: first.id, body: "/clear")
        let controls = ComposerControls(session: first, isFastMode: true, outputStyle: "Concise")

        let next = try await store.replaceWorkspaceConversation(id: first.id, controls: controls)

        #expect(next.id != first.id)
        #expect(next.title == first.title)
        #expect(next.agentSessionID == nil)
        #expect(next.contextTokens == 0)
        #expect(next.model == controls.model)
        #expect(next.effort == controls.effort)
        #expect(next.agentKind == controls.agentKind)
        #expect(next.permissionMode == controls.permissionMode)
        #expect(try await store.setting(ComposerControls.fastModeKey(sessionID: next.id)) == "1")
        #expect(try await store.setting(ComposerControls.outputStyleKey(sessionID: next.id)) == "Concise")
        #expect(try await store.sessions(workspaceID: workspace.id).map(\.id) == [next.id, second.id])
        #expect(try await store.messages(sessionID: next.id).isEmpty)
        #expect(try await store.draft(sessionID: next.id) == "")
        #expect(try await store.session(id: first.id)?.archivedAt != nil)
        #expect(try await store.messages(sessionID: first.id).count == 1)

        await #expect(throws: SQLiteError.self) {
            try await store.replaceWorkspaceConversation(id: first.id, controls: controls)
        }
        #expect(try await store.sessions(workspaceID: workspace.id).map(\.id) == [next.id, second.id])
    }

    @Test(arguments: [true, false])
    func clearingASplitChatPreservesItsPanesAndTabCount(isRoot: Bool) throws {
        let old = PaneContent.chat(SessionID("old"))
        let new = PaneContent.chat(SessionID("new"))
        let neighbour = PaneContent.chat(SessionID("neighbour"))
        let root = isRoot ? old : neighbour
        var layout = SplitLayout(pane: "left")
        layout.split("left", axis: .horizontal, into: "right")
        layout.split("right", axis: .vertical, into: "duplicate")
        layout.setRatio(0.7, at: [])
        layout.setFocus("right")
        let stored = StoredPaneArrangement(
            layout: try #require(layout.encoded),
            contents: ["left": neighbour, "right": old, "duplicate": old]
        )

        let outcome = TabSurgery.replace(old, with: new, in: stored, root: root)

        guard case .updated(let nextRoot, let next) = outcome else {
            Issue.record("Clearing a chat must preserve its split tab")
            return
        }
        #expect(nextRoot == (isRoot ? new : neighbour))
        #expect(next.layout == stored.layout)
        #expect(next.contents == ["left": neighbour, "right": new, "duplicate": new])
        let entries = TabSet.entries(
            sessions: [SessionID("new"), SessionID("neighbour")], tools: [],
            claimed: next.claimedContents(root: nextRoot)
        )
        #expect(entries == [nextRoot])
    }
}
