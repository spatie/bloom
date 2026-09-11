import Foundation
import Testing
@testable import BloomCore

@Suite("Side conversations", .scratchDirectory)
struct SideConversationTests {
    private func fixture(agent: AgentKind = .codex) async throws -> (Store, Session) {
        let store = try makeTestStore("side-conversation")
        let repo = try await store.upsert(Repo(name: "r", path: "/tmp/side-conversation"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "w", branch: "b", path: "/tmp/side-worktree", baseBranch: "main"
        ))
        let parent = try await store.upsert(Session(
            workspaceID: workspace.id, title: "Search work", agentSessionID: "parent-provider-id",
            model: agent == .codex ? "gpt-5.6-sol" : "opus", effort: "high", agentKind: agent,
            permissionMode: .bypassPermissions
        ))
        return (store, try #require(try await store.session(id: parent.id)))
    }

    private func user(_ text: String, sessionID: SessionID, seq: Int = 0) throws -> Message {
        Message(
            sessionID: sessionID, seq: seq, kind: .user,
            payload: Data(try AgentRunner.encodeTurn(text).utf8)
        )
    }

    @Test(arguments: ["/btw", " /btw \n", "/btw Why?", "/btw\nWhy?", "/btw\tWhy?"])
    func commandIsHostOwned(text: String) {
        #expect(SideConversation.question(in: text) != nil)
    }

    @Test(arguments: ["/btwhatever", "Use /btw here", "/BTW", "hello"])
    func ordinaryInputStaysOrdinary(text: String) {
        #expect(SideConversation.question(in: text) == nil)
    }

    @Test(arguments: [AgentKind.codex, .claudeCode])
    func openingInheritsControlsButNeverTheProviderSession(agent: AgentKind) async throws {
        let (store, parent) = try await fixture(agent: agent)
        try await store.setSetting(ComposerControls.fastModeKey(sessionID: parent.id), "1")
        try await store.append(user("Keep the ordering", sessionID: parent.id))
        let child = try await store.openSideConversation(parentID: parent.id, streamingText: "I am checking the filter")
        let reopened = try await store.openSideConversation(parentID: parent.id, streamingText: "Later text")
        #expect(child.id == reopened.id)
        #expect(child.id != parent.id)
        #expect(child.agentSessionID == nil)
        #expect(child.model == parent.model)
        #expect(child.effort == parent.effort)
        #expect(child.agentKind == parent.agentKind)
        #expect(child.permissionMode == parent.permissionMode)
        #expect(child.parentSessionID == nil)
        #expect(child.sideConversationParentID == parent.id)
        #expect(try await store.session(id: parent.id) == parent)
        #expect(try await store.setting(ComposerControls.fastModeKey(sessionID: child.id)) == "1")
        #expect(TabSet.tabbable([parent, child]) == [parent.id])
        let snapshot = try #require(try await store.sideConversationSnapshot(sessionID: child.id))
        #expect(snapshot.context.contains("Keep the ordering"))
        #expect(snapshot.context.contains("I am checking the filter"))
        #expect(!snapshot.context.contains("Later text"))
    }

    @Test func failedFirstSendKeepsContextAndLeavesEditableTextAlone() async throws {
        let (store, parent) = try await fixture()
        try await store.append(user("Original task", sessionID: parent.id))
        let child = try await store.openSideConversation(parentID: parent.id)
        let delivery = try await store.enqueueDelivery(Delivery(targetSessionID: child.id, body: "Why?"))
        let pending = try await store.pendingDeliveries(sessionID: child.id)
        #expect(pending.first?.body == "Why?")
        let first = try await store.sideConversationTurn("Why?", sessionID: child.id)
        #expect(first.contains("Original task"))
        // Codex records the user row before turn/start can reject the request.
        try await store.append(user("Why?", sessionID: child.id))
        let retry = try await store.sideConversationTurn("Why?", sessionID: child.id)
        #expect(retry == first)
        let cancelled = try await store.cancelDelivery(id: delivery.id)
        #expect(cancelled)
        let next = try await store.sideConversationTurn("Another question", sessionID: child.id)
        #expect(next.contains("Original task"))
        try await store.acknowledgeSideConversationContext(sessionID: child.id)
        #expect(try await store.sideConversationTurn("Follow-up", sessionID: child.id) == "Follow-up")
        #expect(try await store.sideConversationTurn("Parent question", sessionID: parent.id) == "Parent question")
    }

    @Test func keptConversationsPassOnTheirStartingContext() async throws {
        let (store, parent) = try await fixture()
        let child = try await store.openSideConversation(parentID: parent.id, streamingText: "Important starting context")
        _ = try await store.keepSideConversation(sessionID: child.id)
        let grandchild = try await store.openSideConversation(parentID: child.id)
        let snapshot = try #require(try await store.sideConversationSnapshot(sessionID: grandchild.id))
        #expect(snapshot.context.contains("Important starting context"))
    }

    @Test func promotionPreservesLiveSessionAndOrigin() async throws {
        let (store, parent) = try await fixture()
        let child = try await store.openSideConversation(parentID: parent.id)
        try await store.saveDraft(sessionID: child.id, body: "Unfinished question")
        _ = try await store.update(sessionID: child.id) {
            $0.agentSessionID = "child-provider-id"
            $0.inputTokens = 123
            $0.apply(.turnStarted)
        }
        let kept = try #require(try await store.keepSideConversation(sessionID: child.id))
        #expect(kept.sideConversationParentID == nil)
        #expect(kept.agentSessionID == "child-provider-id")
        #expect(kept.inputTokens == 123)
        #expect(kept.state == .running)
        #expect(try await store.draft(sessionID: child.id) == "Unfinished question")
        #expect(try await store.sideConversationSnapshot(sessionID: child.id)?.parentID == parent.id)
        #expect(TabSet.tabbable([parent, kept]) == [parent.id, kept.id])
        let next = try await store.openSideConversation(parentID: parent.id)
        #expect(next.id != kept.id)
    }

    @Test func closingParentMakesItsChildReachable() async throws {
        let (store, parent) = try await fixture()
        let child = try await store.openSideConversation(parentID: parent.id)
        _ = try await store.update(sessionID: parent.id) { $0.archivedAt = Date() }
        let saved = try #require(try await store.session(id: child.id))
        #expect(saved.sideConversationParentID == nil)
        #expect(saved.archivedAt == nil)
        #expect(TabSet.tabbable([saved]) == [child.id])
        await #expect(throws: SQLiteError.self) { try await store.openSideConversation(parentID: parent.id) }
    }

    @Test func planApprovalInheritsTheParentsRememberedMode() async throws {
        let (store, parent) = try await fixture(agent: .claudeCode)
        try await store.setSetting(AppDefaults.Key.permissionMode, PermissionMode.bypassPermissions.rawValue)
        try await store.updateSessionPreferences(id: parent.id, permissionMode: .plan, implementationMode: .auto)
        let child = try await store.openSideConversation(parentID: parent.id)
        #expect(child.permissionMode == .plan)
        #expect(try await store.planImplementationMode(sessionID: child.id, hasWorktree: true) == .auto)
    }

    @Test func nestedSideConversationsAreRefused() async throws {
        let (store, parent) = try await fixture()
        let child = try await store.openSideConversation(parentID: parent.id)
        await #expect(throws: SQLiteError.self) { try await store.openSideConversation(parentID: child.id) }
    }

    @Test func snapshotIncludesAssistantTextAndBoundsLargeResults() throws {
        let id = SessionID.new()
        let answer = Message(sessionID: id, seq: 1, kind: .assistantText, payload: Data(
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Preserve the order"}]}}"#.utf8
        ))
        let context = SideConversation.context(messages: [try user("Search", sessionID: id), answer])
        #expect(context.contains("Search"))
        #expect(context.contains("Preserve the order"))
        let bounded = SideConversation.context(messages: [], streamingText: String(repeating: "x", count: 100_000))
        #expect(bounded.count < SideConversation.contextLimit + 100)
        #expect(bounded.hasPrefix("[Earlier context omitted]"))
    }
}
