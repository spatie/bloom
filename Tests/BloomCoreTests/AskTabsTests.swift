import Foundation
import Testing
@testable import BloomCore

@Suite("Ask conversation tabs", .scratchDirectory)
struct AskTabsTests {
    @Test func closingTheMiddleAskTabSelectsLeftOnlyWhenActive() {
        let sessions = (0..<3).map { _ in AskConversation.newSession() }
        let middle = sessions[1].id
        #expect(AskTabs.selectionAfterClosing(middle, selected: middle, sessions: sessions) == sessions[0].id)
        #expect(AskTabs.selectionAfterClosing(middle, selected: sessions[2].id, sessions: sessions) == sessions[2].id)
    }

    @Test func creatingTabsPreservesConversationsAndDirectories() async throws {
        let store = try makeTestStore("ask-tabs")
        let first = try await store.createAskConversation(directory: "/first")
        let second = try await store.createAskConversation(directory: "/second")
        let sessions = try await store.sessionsWithoutWorkspace()
        #expect(sessions.map(\.id) == [first.id, second.id])
        #expect(try await store.session(id: first.id)?.archivedAt == nil)
        #expect(try await store.setting(AskTabs.directoryKey(first.id)) == "/first")
        #expect(try await store.setting(AskTabs.directoryKey(second.id)) == "/second")
        let saved = try await store.setting(AskTabs.selectionKey)
        #expect(AskTabs.selection(saved: saved, sessions: sessions) == second.id)
        #expect(AskTabs.selection(saved: "missing", sessions: sessions) == first.id)
        #expect(AskTabs.selectionAfterClosing(first.id, selected: second.id, sessions: sessions) == second.id)
        #expect(AskTabs.selectionAfterClosing(second.id, selected: second.id, sessions: sessions) == first.id)
        #expect(AskTabs.selectionAfterClosing(first.id, selected: first.id, sessions: [first]) == nil)
    }

    @Test func unreadConversationsRequireAnUnseenFinishedTurn() async throws {
        let store = try makeTestStore("ask-unread-conversations")
        let chat = try await store.createAskConversation(directory: "/first")
        _ = try await store.createAskConversation(directory: "/second")

        try await store.appendNext(sessionID: chat.id, kind: .user, payload: Data("hello".utf8))
        #expect(try await store.unreadProjectFreeConversationIDs().isEmpty)

        try await store.appendNext(sessionID: chat.id, kind: .result, payload: Data("{}".utf8))
        #expect(try await store.unreadProjectFreeConversationIDs() == Set([chat.id]))

        try await store.updateLastReadSeq(sessionID: chat.id, seq: 1)
        #expect(try await store.unreadProjectFreeConversationIDs().isEmpty)

        try await store.appendNext(sessionID: chat.id, kind: .result, payload: Data("{}".utf8))
        _ = try await store.closeAskConversation(id: chat.id, selected: chat.id)
        #expect(try await store.unreadProjectFreeConversationIDs().isEmpty)
    }

    @Test func replacingOneTabPreservesItsLocationAndNeighbours() async throws {
        let store = try makeTestStore("ask-replace-tab")
        let first = try await store.createAskConversation(directory: "/first")
        let second = try await store.createAskConversation(directory: "/second")
        let controls = ComposerControls(session: first, isFastMode: true, outputStyle: "Concise")
        let replacement = try await store.replaceAskConversation(id: first.id, controls: controls, draft: "next")
        #expect(try await store.setting(AskTabs.directoryKey(replacement.id)) == "/first")
        #expect(try await store.sessionsWithoutWorkspace().map(\.id) == [replacement.id, second.id])
        #expect(try await store.session(id: first.id)?.archivedAt != nil)
    }

    @Test func replacementCanUseItsOwnDirectory() async throws {
        let store = try makeTestStore("conversation-replacement-directory")
        let first = try await store.createAskConversation(directory: "/first")
        let nextID = SessionID.new()
        let directory = AskConversation.workspaceDirectory(
            besideDatabaseAt: store.path, id: nextID
        )
        let replacement = try await store.replaceAskConversation(
            id: first.id, controls: ComposerControls(
                session: first, isFastMode: false, outputStyle: OutputStyle.defaultName
            ),
            nextID: nextID, replacementDirectory: directory
        )

        #expect(replacement.id == nextID)
        #expect(try await store.setting(AskTabs.directoryKey(first.id)) == "/first")
        #expect(try await store.setting(AskTabs.directoryKey(nextID)) == directory)
    }

    @Test func missingCustomDirectoryDoesNotFallBack() throws {
        let root = TestScratch.unique("ask-custom-directory")
        #expect(AskTabs.prepareDirectory(root + "/missing", databasePath: root + "/db") == nil)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        #expect(AskTabs.prepareDirectory(root, databasePath: root + "/db") == root)
        try Data().write(to: URL(fileURLWithPath: root + "/file"))
        #expect(AskTabs.prepareDirectory(root + "/file", databasePath: root + "/db") == nil)
    }
    @Test func closingArchivesWithoutDeletingAndKeepsTheLastTab() async throws {
        let store = try makeTestStore("ask-close-tab")
        let first = try await store.createAskConversation(directory: "/first", draft: "keep this")
        let second = try await store.createAskConversation(directory: "/second")
        let selected = try await store.closeAskConversation(id: first.id, selected: first.id)
        #expect(selected == second.id)
        #expect(try await store.setting(AskTabs.selectionKey) == second.id.rawValue)
        #expect(try await store.session(id: first.id)?.archivedAt != nil)
        #expect(try await store.draft(sessionID: first.id) == "keep this")
        _ = try await store.closeAskConversation(id: second.id, selected: second.id)
        #expect(try await store.sessionsWithoutWorkspace().map(\.id) == [second.id])
    }

    @Test func newTabCarriesControlsAndDraftAtomically() async throws {
        let store = try makeTestStore("ask-tab-controls")
        let controls = ComposerControls(session: AskConversation.newSession(), isFastMode: true,
                                        outputStyle: "Concise", codexFastMode: false, advisor: .sonnet)
        let chat = try await store.createAskConversation(directory: "/chosen", controls: controls, draft: "hello")
        #expect(try await store.draft(sessionID: chat.id) == "hello")
        #expect(try await store.setting(ComposerControls.fastModeKey(sessionID: chat.id)) == "1")
        #expect(try await store.setting(CodexSpeed.key(sessionID: chat.id)) == "0")
        #expect(try await store.setting(ComposerControls.outputStyleKey(sessionID: chat.id)) == "Concise")
        #expect(try await store.setting(ChatAdvisor.key(sessionID: chat.id)) == "sonnet")
    }

    @Test func projectFreeConversationCanBeArchivedRestoredAndDeleted() async throws {
        let store = try makeTestStore("conversation-workspace-lifecycle")
        let conversation = try await store.createAskConversation(
            directory: "/conversations", draft: "keep this", title: "A loose conversation"
        )
        try await store.append(Message(
            sessionID: conversation.id, seq: 0, kind: .user, payload: Data("Hello".utf8)
        ))
        let neighbour = try await store.createAskConversation(directory: "/another")

        #expect(conversation.workspaceID == nil)
        #expect(conversation.title == "A loose conversation")
        #expect(try await store.projectFreeSessionsWithHistory().contains(conversation.id))
        #expect(try await store.deleteArchivedConversation(id: conversation.id) == false)

        _ = try await store.closeAskConversation(id: conversation.id, selected: conversation.id)
        #expect(try await store.sessionsWithoutWorkspace().map(\.id) == [neighbour.id])
        #expect(try await store.sessionsWithoutWorkspace(includeArchived: true).map(\.id) == [conversation.id])

        let restored = try #require(await store.restoreConversation(id: conversation.id))
        #expect(restored.archivedAt == nil)
        #expect(try await store.setting(AskTabs.selectionKey) == conversation.id.rawValue)
        #expect(try await store.draft(sessionID: conversation.id) == "keep this")
        #expect(try await store.messageCount(sessionID: conversation.id) == 1)
        #expect(try await store.restoreConversation(id: conversation.id) == nil)

        _ = try await store.closeAskConversation(id: conversation.id, selected: conversation.id)
        #expect(try await store.deleteArchivedConversation(id: conversation.id))
        #expect(try await store.session(id: conversation.id) == nil)
        #expect(try await store.messageCount(sessionID: conversation.id) == 0)
        #expect(try await store.session(id: neighbour.id) != nil)
    }

    @Test func legacyTitleDoesNotHideAnArchivedDraft() async throws {
        let store = try makeTestStore("legacy-conversation-draft")
        let old = try await store.createAskConversation(
            directory: "/old", draft: "saved words", title: "Ask Bloom"
        )
        _ = try await store.createAskConversation(directory: "/next")
        _ = try await store.closeAskConversation(id: old.id, selected: old.id)

        #expect(AskConversation.isBlank(old))
        #expect(try await store.projectFreeSessionsWithHistory(includeArchived: true).contains(old.id))
    }

    @Test func legacyConversationKeepsItsOriginalDirectoryWhenReplaced() async throws {
        let store = try makeTestStore("ask-tab-legacy")
        let original = try await store.upsert(AskConversation.newSession())
        try await store.setSetting(DirectoryPreferences.askKey, "/new-default")
        let controls = ComposerControls(session: original, isFastMode: false, outputStyle: "")
        let chat = try await store.replaceAskConversation(id: original.id, controls: controls)
        #expect(try await store.setting(AskTabs.directoryKey(chat.id)) == AskConversation.directory(besideDatabaseAt: store.path))
    }

}
