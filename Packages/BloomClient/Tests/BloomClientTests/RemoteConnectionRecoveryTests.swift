import Foundation
import Testing
@testable import BloomClient

struct RemoteConnectionRecoveryTests {
    @Test func retriesBackOffAndExplicitDisconnectStaysDisconnected() {
        var recovery = RemoteConnectionRecovery()
        recovery.beginAttempt()
        #expect(recovery.phase == .connecting)
        recovery.connected()
        recovery.failed(message: "Network unavailable")
        #expect(recovery.canRetry && recovery.automaticallyRetries)
        #expect(recovery.retryDelaySeconds == 2)
        recovery.beginAttempt()
        #expect(recovery.phase == .reconnecting)
        for _ in 0..<30 { recovery.failed(message: "Network unavailable") }
        #expect(recovery.retryDelaySeconds == 30)
        recovery.connected()
        #expect(recovery.failureCount == 0 && recovery.lastError == nil)
        recovery.disconnect()
        #expect(!recovery.automaticallyRetries && recovery.phase == .disconnected)
    }

    @Test func cancellingAnAttemptStopsTheIndicatorAndPreservesFailureDetails() {
        var recovery = RemoteConnectionRecovery()
        recovery.failed(message: "Connecting over SSH: Permission denied (publickey)", automaticallyRetry: false)
        recovery.beginAttempt()
        recovery.cancelAttempt()
        #expect(recovery.phase == .disconnected)
        #expect(!recovery.automaticallyRetries)
        #expect(recovery.canRetry)
        #expect(recovery.lastError == "Connecting over SSH: Permission denied (publickey)")
    }

    @Test func cancellingBackgroundRecoveryRemainsRetryableWithoutStayingConnecting() {
        var recovery = RemoteConnectionRecovery()
        recovery.connected()
        recovery.failed(message: "Network unavailable")
        recovery.beginAttempt()
        recovery.cancelAttempt(automaticallyRetry: true)
        #expect(recovery.phase == .offline)
        #expect(recovery.automaticallyRetries && recovery.canRetry)
        #expect(recovery.lastError == "Network unavailable")
        recovery.beginAttempt()
        recovery.connected()
        #expect(recovery.lastError == nil)
    }

    @Test(arguments: ["Permission denied (publickey)", "The server's SSH host key has changed.",
                      "This server uses another version. Update Bloom Server and the app.", "Sign-in expired"])
    func identityAndAccountFailuresNeedUserAction(message: String) {
        #expect(RemoteConnectionRecovery.requiresUserAction(message))
        var recovery = RemoteConnectionRecovery()
        recovery.failed(message: message, automaticallyRetry: false)
        #expect(recovery.canRetry && !recovery.automaticallyRetries)
        #expect(recovery.lastError == message)
    }

    @Test func filePermissionsDoNotMeanTheConnectionNeedsAuthentication() {
        #expect(!RemoteConnectionRecovery.requiresUserAction("Could not read workspace file: Permission denied"))
    }

    @MainActor @Test func lostAcknowledgementSurvivesOtherCommandsAndEditedDraftWithoutDuplicateSend() async throws {
        let suite = "bloom-reconnect-tests." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let scope = ConversationDraftStore.Scope(connectionID: "server")
        let session = SessionID("chat")
        let store = ConversationDraftStore(preferences: preferences, key: "drafts")
        try store.save(text: "Please review", scope: scope, sessionID: session)
        let expanded = "Please review `remote/attachment.png`"
        let original = try store.prepare(scope: scope, sessionID: session, text: expanded)
        let transport = RecoveryConnection()
        await #expect(throws: ConnectionFailure.self) { try await transport.request(original) }
        _ = try await transport.request(.call("configure"))
        try store.save(text: "My next thought", scope: scope, sessionID: session)
        let relaunched = ConversationDraftStore(preferences: preferences, key: "drafts")
        #expect(throws: ConnectionFailure.self) {
            try relaunched.prepare(scope: scope, sessionID: session, text: "My next thought")
        }
        #expect(await transport.executions == 1)
        // Reconnecting and reopening a draft do not replay its submission.
        let restored = try relaunched.draft(scope: scope, sessionID: session)
        #expect(restored.submission == original && restored.text == "My next thought")
        let retry = try relaunched.prepare(scope: scope, sessionID: session, text: expanded)
        #expect(retry == original)
        _ = try await transport.request(retry)
        try relaunched.acknowledge(retry, scope: scope, sessionID: session)
        let acknowledged = try relaunched.draft(scope: scope, sessionID: session)
        #expect(acknowledged.submission == nil && acknowledged.text == "My next thought")
        #expect(await transport.executions == 1)
    }

    @Test func reconnectCatchesUpFromExistingCursorAndRetainsCachedMessagesWhileOffline() async throws {
        let transport = RecoveryConnection()
        let service = RemoteWorkspaceService(client: transport)
        var buffer = TranscriptBuffer()
        let initial = try await service.transcript(sessionID: SessionID("chat"), after: buffer.sequence)
        buffer.apply(initial)
        await transport.goOffline()
        await #expect(throws: ConnectionFailure.self) {
            try await service.transcript(sessionID: SessionID("chat"), after: buffer.sequence)
        }
        #expect(buffer.messages.map(\.seq) == [1, 2])
        await transport.reconnect()
        let resumed = try await service.transcript(sessionID: SessionID("chat"), after: buffer.sequence)
        buffer.apply(resumed)
        #expect(buffer.messages.map(\.seq) == [1, 2, 3])
        #expect(await transport.cursors == [0, 2, 2])
    }
}

private actor RecoveryConnection: RemoteRequesting {
    private var receipts: Set<UUID> = []
    private(set) var executions = 0
    private(set) var cursors: [Int] = []
    private var offline = false
    private var count = 2
    func goOffline() { offline = true; count = 3 }
    func reconnect() { offline = false }

    func request(_ command: RemoteCommand) async throws -> JSONValue {
        if let cursor = command.operation["transcript"]?["afterSeq"]?.intValue {
            cursors.append(cursor)
            if offline { throw ConnectionFailure("Network unavailable") }
            let messages: [JSONValue] = try (1...count).filter { $0 > cursor }.map { seq in
                let payload = try JSONEncoder().encode(JSONValue.object(["text": .string("Message \(seq)")]))
                return .object(["id": .integer(seq), "seq": .integer(seq), "kind": .string("assistantText"), "payload": .string(payload.base64EncodedString())])
            }
            return .object(["transcript": .object(["_0": .object([
                "session": .object(["id": .string("chat"), "title": .string("Chat"), "model": .string("model"), "agentKind": .string("codex"), "state": .string("idle")]),
                "messages": .array(messages), "pendingQuestions": .array([]), "isBusy": .bool(false), "streamingText": .string("")
            ])])])
        }
        if command.operation["send"] != nil, receipts.insert(command.id).inserted {
            executions += 1
            throw ConnectionFailure("Connection lost after the server accepted the message")
        }
        return .object(["accepted": .object([:])])
    }
}
