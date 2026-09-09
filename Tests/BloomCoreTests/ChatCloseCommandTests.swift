import Foundation
import Testing
@testable import BloomCore

@Suite(.scratchDirectory) struct ChatCloseCommandTests {
    @Test func handlesOnlyTheStandaloneHostCommand() {
        for text in ["/close", "/close ", " \n/close\n"] {
            #expect(ChatCloseCommand.matches(text))
        }
        for text in ["", "/closed", "/close everything", "Please add /close", "`/close`", "/CLOSE"] {
            #expect(!ChatCloseCommand.matches(text))
        }
        #expect(SlashCommandIndex.builtIns.contains { $0.name == "close" })
        #expect(ChatClearCommand.matches("/clear"))
        #expect(!ChatClearCommand.matches("/close"))
    }

    @Test func replacesOnlyTheCurrentWorkspaceChatAndCarriesItsControls() async throws {
        let store = try makeTestStore("close-chat")
        let repo = try await store.upsert(Repo(name: "r", path: TestScratch.unique("repo")))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "w", branch: "feature", path: TestScratch.unique("worktree"), baseBranch: "main"
        ))
        let first = try await store.upsert(Session(workspaceID: workspace.id, title: "Chat", sortOrder: 0))
        let second = try await store.upsert(Session(workspaceID: workspace.id, title: "Chat 2", sortOrder: 1))
        try await store.saveDraft(sessionID: first.id, body: "keep this")
        var controls = ComposerControls(session: first, isFastMode: true, outputStyle: "Concise")
        controls.model = "test-model"
        controls.effort = "high"
        controls.agentKind = .codex
        let next = try await store.replaceWorkspaceConversation(id: first.id, controls: controls)
        #expect(next.id != first.id)
        #expect(next.workspaceID == workspace.id)
        #expect(next.title == first.title)
        #expect(next.sortOrder == first.sortOrder)
        #expect(next.model == controls.model)
        #expect(next.effort == controls.effort)
        #expect(next.agentKind == controls.agentKind)
        #expect(next.permissionMode == controls.permissionMode)
        #expect(next.agentSessionID == nil)
        #expect(try await store.session(id: first.id)?.archivedAt != nil)
        #expect(try await store.session(id: second.id)?.archivedAt == nil)
        #expect(try await store.draft(sessionID: first.id) == "keep this")
        #expect(try await store.setting(ComposerControls.fastModeKey(sessionID: next.id)) == "1")
        #expect(try await store.setting(ComposerControls.outputStyleKey(sessionID: next.id)) == "Concise")
        await #expect(throws: SQLiteError.self) {
            try await store.replaceWorkspaceConversation(id: first.id, controls: controls)
        }
        #expect(try await store.sessions(workspaceID: workspace.id).map(\.id) == [next.id, second.id])
    }

    @Test func workspaceReplacementRejectsAskConversations() async throws {
        let store = try makeTestStore("close-ask-guard")
        let ask = try await store.createAskConversation(directory: "/tmp")
        let controls = ComposerControls(session: ask, isFastMode: false, outputStyle: "")
        await #expect(throws: SQLiteError.self) {
            try await store.replaceWorkspaceConversation(id: ask.id, controls: controls)
        }
        #expect(try await store.session(id: ask.id)?.archivedAt == nil)
    }
}
