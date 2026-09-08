import Foundation
import Testing
@testable import BloomCore

@Suite("Ask conversation tabs", .scratchDirectory)
struct AskTabsTests {
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
        let controls = ComposerControls(session: AskConversation.newSession(), isFastMode: true, outputStyle: "Concise")
        let chat = try await store.createAskConversation(directory: "/chosen", controls: controls, draft: "hello")
        #expect(try await store.draft(sessionID: chat.id) == "hello")
        #expect(try await store.setting(ComposerControls.fastModeKey(sessionID: chat.id)) == "1")
        #expect(try await store.setting(ComposerControls.outputStyleKey(sessionID: chat.id)) == "Concise")
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
