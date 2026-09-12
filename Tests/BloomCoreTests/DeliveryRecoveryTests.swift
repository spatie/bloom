import Foundation
import Testing
@testable import BloomCore

@Suite(.scratchDirectory) struct DeliveryRecoveryTests {
    @Test func aClaimSurvivesRestartWithOneLinkedMessageAndNoAutomaticDispatch() async throws {
        let store = try makeTestStore("delivery-claim-restart")
        let session = try await store.upsert(AskConversation.newSession())
        let delivery = try await store.enqueueDelivery(Delivery(targetSessionID: session.id, body: "Do the work"))
        let claimed = try await store.claimDelivery(id: delivery.id)
        #expect(claimed)
        let reopened = try Store(path: store.path)
        try await reopened.recoverDeliveryClaims()
        let restored = try #require(await reopened.pendingDeliveries(sessionID: session.id).first)
        #expect(restored.state == .pending)
        #expect(restored.deliveredSeq != nil)
        let reclaimed = try await reopened.claimDelivery(id: delivery.id)
        #expect(reclaimed)
        #expect(try await reopened.messages(sessionID: session.id).count == 1)
    }

    @Test func anUnknownOutcomeBlocksLaterMessagesUntilAnExplicitRetry() async throws {
        let store = try makeTestStore("delivery-uncertain")
        let session = try await store.upsert(AskConversation.newSession())
        let first = try await store.enqueueDelivery(Delivery(targetSessionID: session.id, body: "First"))
        _ = try await store.enqueueDelivery(Delivery(targetSessionID: session.id, body: "Second"))
        _ = try await store.claimDelivery(id: first.id)
        try await store.beginDeliveryDispatch(id: first.id)
        let reopened = try Store(path: store.path)
        try await reopened.recoverDeliveryClaims()
        let waiting = try await reopened.pendingDeliveries(sessionID: session.id)
        #expect(waiting.first?.state == .uncertain)
        #expect(Delivery.deliverable(from: waiting, hold: .none, on: .codex).isEmpty)
        #expect(!Delivery.goesImmediately(behind: waiting, hold: .none, on: .codex))
        try await reopened.restoreDelivery(id: first.id)
        _ = try await reopened.claimDelivery(id: first.id)
        try await reopened.beginDeliveryDispatch(id: first.id)
        try await reopened.acceptDelivery(id: first.id, providerTurnID: "turn-42")
        #expect(try await reopened.delivery(id: first.id)?.providerTurnID == "turn-42")
        #expect(try await reopened.messages(sessionID: session.id).count == 1)
        #expect(try await reopened.pendingDeliveries(sessionID: session.id).count == 1)
    }

    @Test func failedMessageInsertionRollsBackTheClaim() async throws {
        let store = try makeTestStore("delivery-atomic-claim")
        let session = try await store.upsert(AskConversation.newSession())
        let delivery = try await store.enqueueDelivery(Delivery(targetSessionID: session.id, body: "Keep me"))
        let raw = try SQLiteDatabase(path: store.path)
        try raw.execute("CREATE TRIGGER fail_message BEFORE INSERT ON messages BEGIN SELECT RAISE(ABORT, 'disk full'); END")
        await #expect(throws: SQLiteError.self) { try await store.claimDelivery(id: delivery.id) }
        #expect(try await store.delivery(id: delivery.id)?.state == .pending)
        #expect(try await store.messages(sessionID: session.id).isEmpty)
    }

    @Test func ownerMessagesCaptureInteractionModeAtEnqueue() async throws {
        let store = try makeTestStore("delivery-mode")
        let session = try await store.upsert(Session(workspaceID: nil, agentKind: .codex, interactionMode: .plan))
        let delivery = try await store.enqueueDelivery(Delivery(targetSessionID: session.id, body: "Plan first"))
        try await store.updateSessionPreferences(id: session.id, interactionMode: .build)
        #expect(delivery.interactionMode == .plan)
        #expect(try await store.delivery(id: delivery.id)?.interactionMode == .plan)
    }
}
