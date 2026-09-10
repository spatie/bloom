import Foundation
import Testing
@testable import BloomClient

@MainActor
struct DraftTests {
    private func location() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("drafts.json") }

    @Test func connectionScopesKeepClonedSessionDraftsSeparateAcrossRelaunch() throws {
        let suite = "bloom-drafts-test." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let original = ConversationDraftStore.Scope(connectionID: "original-server")
        let clone = ConversationDraftStore.Scope(connectionID: "cloned-server")
        let session = SessionID("same-uuid")
        let store = ConversationDraftStore(preferences: preferences, key: "drafts")
        try store.save(text: "Original private draft", scope: original, sessionID: session)
        try store.save(text: "Clone draft", scope: clone, sessionID: session)
        let relaunched = ConversationDraftStore(preferences: preferences, key: "drafts")
        #expect(try relaunched.draft(scope: original, sessionID: session).text == "Original private draft")
        #expect(try relaunched.draft(scope: clone, sessionID: session).text == "Clone draft")
        try relaunched.save(text: "Original draft with late attachment", scope: original, sessionID: session)
        #expect(try relaunched.draft(scope: clone, sessionID: session).text == "Clone draft")
    }

    @Test func legacyMigrationOnlyPopulatesItsKnownOriginalScopeAndPreservesNewerDrafts() throws {
        let file = location()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = ConversationDraftStore(file: file)
        let original = ConversationDraftStore.Scope(connectionID: "original")
        let other = ConversationDraftStore.Scope(connectionID: "other")
        try store.save(text: "Newer text", scope: original, sessionID: .init("existing"))
        try store.importLegacy(["existing": "Stale text", "legacy": "Recovered text"], scope: original)
        #expect(try store.draft(scope: original, sessionID: .init("existing")).text == "Newer text")
        #expect(try store.draft(scope: original, sessionID: .init("legacy")).text == "Recovered text")
        #expect(try store.draft(scope: other, sessionID: .init("legacy")).text.isEmpty)
    }

    @Test func corruptPreferenceDraftsAreNotSilentlyReplaced() throws {
        let suite = "bloom-drafts-test." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set("unreadable", forKey: "drafts")
        let store = ConversationDraftStore(preferences: preferences, key: "drafts")
        #expect(throws: ConnectionFailure.self) {
            try store.save(text: "New text", scope: .init(connectionID: "server"), sessionID: .init("session"))
        }
        #expect(preferences.string(forKey: "drafts") == "unreadable")
    }

    @Test func sshDraftsAreScopedToAccountAndRuntime() throws {
        let file = location()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = ConversationDraftStore(file: file)
        let session = SessionID("same")
        try store.save(text: "SSH draft", origin: "ssh://bloom@SERVER.example:22/var/lib/bloom", sessionID: session)
        #expect(try store.draft(origin: "ssh://bloom@server.example/var/lib/bloom", sessionID: session).text == "SSH draft")
        #expect(try store.draft(origin: "ssh://other@server.example/var/lib/bloom", sessionID: session).text.isEmpty)
        #expect(try store.draft(origin: "ssh://bloom@server.example/var/lib/another", sessionID: session).text.isEmpty)
        #expect(throws: ConnectionFailure.self) { try store.save(text: "no", origin: "ssh://bloom:secret@server.example/var/lib/bloom", sessionID: session) }
    }

    @Test func matchingServerFailureDoesNotProveTheCommandNeverRan() async throws {
        let file = location()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = ConversationDraftStore(file: file)
        let origin = "https://server.example"
        let session = SessionID("one")
        try store.save(text: "Run tests", origin: origin, sessionID: session)
        let command = try store.prepare(origin: origin, sessionID: session)
        await #expect(throws: ConnectionRefusal.self) {
            try await store.submit(using: InterruptedJournalClient(), origin: origin, sessionID: session)
        }
        let relaunched = ConversationDraftStore(file: file)
        #expect(try relaunched.prepare(origin: origin, sessionID: session) == command)
        #expect(try relaunched.draft(origin: origin, sessionID: session).text == "Run tests")
    }

    @Test func transportFailureAndUnexpectedReplyKeepRetryIdentityAfterRelaunch() async throws {
        let file = location()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let origin = "https://server.example"
        let session = SessionID("one")
        let store = ConversationDraftStore(file: file)
        try store.save(text: "Run tests", origin: origin, sessionID: session)
        let connection = DraftConnection()
        await #expect(throws: ConnectionFailure.self) { try await store.submit(using: connection, origin: origin, sessionID: session) }
        let failed = try store.draft(origin: origin, sessionID: session)
        let relaunched = ConversationDraftStore(file: file)
        await connection.respond(.object(["unexpected": .object([:])]))
        await #expect(throws: ConnectionFailure.self) { try await relaunched.submit(using: connection, origin: origin, sessionID: session) }
        #expect(try relaunched.draft(origin: origin, sessionID: session) == failed)
        await connection.respond(.object(["accepted": .object([:])]))
        try await relaunched.submit(using: connection, origin: origin, sessionID: session)
        #expect(try relaunched.draft(origin: origin, sessionID: session).text.isEmpty)
        let sent = await connection.commands
        #expect(sent.count == 3)
        #expect(Set(sent.map(\.id)).count == 1)
        #expect(sent.allSatisfy { $0 == failed.submission })
    }

    @Test func relaunchRetainsExactSubmissionAndNewerDraft() throws {
        let file = location()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = ConversationDraftStore(file: file)
        let session = SessionID("one")
        try store.save(text: "Original turn", origin: "https://SERVER.example:443/", sessionID: session)
        let command = try store.prepare(origin: "https://server.example", sessionID: session)
        try store.save(text: "Next thought", origin: "https://server.example", sessionID: session)
        let relaunched = ConversationDraftStore(file: file)
        #expect(try relaunched.prepare(origin: "https://server.example/", sessionID: session) == command)
        #expect(command.operation["send"]?["text"]?.stringValue == "Original turn")
        try relaunched.acknowledge(command, origin: "https://server.example", sessionID: session)
        let remaining = try relaunched.draft(origin: "https://server.example", sessionID: session)
        #expect(remaining.text == "Next thought")
        #expect(remaining.submission == nil)
    }

    @Test func acknowledgementsOnlyClearTheirOwnExactSubmission() throws {
        let file = location()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = ConversationDraftStore(file: file)
        let session = SessionID("same")
        try store.save(text: "One", origin: "https://first.example", sessionID: session)
        try store.save(text: "Two", origin: "https://second.example", sessionID: session)
        try store.save(text: "Port", origin: "https://first.example:444", sessionID: session)
        try store.save(text: "Other session", origin: "https://first.example", sessionID: SessionID("other"))
        let command = try store.prepare(origin: "https://first.example", sessionID: session)
        try store.acknowledge(.send(sessionID: session, text: "One"), origin: "https://first.example", sessionID: session)
        #expect(try store.draft(origin: "https://first.example", sessionID: session).submission == command)
        try store.acknowledge(command, origin: "https://second.example", sessionID: session)
        #expect(try store.draft(origin: "https://second.example", sessionID: session).text == "Two")
        try store.acknowledge(command, origin: "https://first.example", sessionID: session)
        #expect(try store.draft(origin: "https://first.example", sessionID: session).text.isEmpty)
        #expect(try store.draft(origin: "https://first.example:444", sessionID: session).text == "Port")
        #expect(try store.draft(origin: "https://first.example", sessionID: SessionID("other")).text == "Other session")
    }

    @Test func corruptedStorageAndCredentialAddressesCannotOverwriteDrafts() throws {
        let file = location()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = ConversationDraftStore(file: file)
        try store.save(text: "Saved", origin: "https://server.example", sessionID: SessionID("one"))
        let original = try Data(contentsOf: file)
        #expect(throws: (any Error).self) {
            try store.save(text: "Secret", origin: "https://user:password@server.example", sessionID: SessionID("one"))
        }
        #expect(try Data(contentsOf: file) == original)
        try Data("invalid".utf8).write(to: file)
        #expect(throws: (any Error).self) { try store.prepare(origin: "https://server.example", sessionID: SessionID("one")) }
        #expect(try Data(contentsOf: file) == Data("invalid".utf8))
    }

    @Test func diskFailurePreventsPreparingNetworkCommand() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("file".utf8).write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationDraftStore(file: directory.appendingPathComponent("drafts.json"))
        #expect(throws: (any Error).self) { try store.save(text: "Do work", origin: "https://server.example", sessionID: SessionID("one")) }
        #expect(throws: (any Error).self) { try store.prepare(origin: "https://server.example", sessionID: SessionID("one")) }
    }
}

private struct InterruptedJournalClient: RemoteRequesting {
    func request(_ command: RemoteCommand) async throws -> JSONValue {
        let reply: JSONValue = .object([
            "version": .integer(BloomWire.version), "id": .string(command.id.uuidString),
            "result": .object(["failure": .object(["_0": .string("The server stopped while handling this command. Inspect the workspace before submitting a new command.")])])
        ])
        return try RemoteClient.decode(JSONEncoder().encode(reply), commandID: command.id)
    }
}

private actor DraftConnection: RemoteRequesting {
    var commands: [RemoteCommand] = []
    private var result: JSONValue?
    func respond(_ result: JSONValue) { self.result = result }
    func request(_ command: RemoteCommand) async throws -> JSONValue {
        commands.append(command)
        guard let result else { throw ConnectionFailure("Connection lost after sending") }
        return result
    }
}
