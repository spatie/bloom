import Foundation
import Testing
@testable import BloomCore

@Suite("Transcript rewind", .scratchDirectory)
struct TranscriptRewindTests {
    private func fixture(_ store: Store) async throws -> (Session, Delivery, TurnCheckpoint) {
        let repo = try await store.upsert(Repo(name: "rewind", path: "/tmp/rewind"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "w", branch: "topic", path: "/tmp/rewind-w", baseBranch: "main"
        ))
        let session = try await store.upsert(Session(workspaceID: workspace.id, agentKind: .codex))
        _ = try await store.appendNext(sessionID: session.id, kind: .notice, payload: Data("{}".utf8))
        let delivery = Delivery(targetSessionID: session.id, body: "Fix this `.bloom/attachments/img/shot.png`")
        _ = try await store.enqueueDelivery(delivery)
        let claimed = try await store.claimDelivery(id: delivery.id)
        #expect(claimed)
        try await store.beginDeliveryDispatch(id: delivery.id)
        try await store.acceptDelivery(id: delivery.id, providerTurnID: "provider-turn")
        let sent = try #require(await store.delivery(id: delivery.id))
        let seq = try #require(sent.deliveredSeq)
        _ = try await store.appendNext(sessionID: session.id, kind: .result, payload: Data("{}".utf8))
        var checkpoint = TurnCheckpoint(sessionID: session.id, startSeq: seq, before: GitSnapshot(sessionID: session.id))
        checkpoint.providerTurnID = "provider-turn"
        try await store.saveTurnCheckpoint(checkpoint)
        return (session, sent, checkpoint)
    }

    @Test("Confirmed rewind atomically restores draft and retains a transcript backup without replaying deliveries")
    func completeAndReopen() async throws {
        let path = TestScratch.unique("transcript-rewind") + ".sqlite"
        let store = try Store(path: path)
        let (session, delivery, checkpoint) = try await fixture(store)
        try await store.saveDraft(sessionID: session.id, body: "An existing draft")
        _ = try await store.prepareTranscriptRewind(checkpoint)
        var journal = CheckpointRewind(checkpoint: checkpoint, recovery: nil, restoringFiles: false)
        try await store.saveCheckpointRewind(journal)
        journal.stage = .providerReverted
        try await store.saveCheckpointRewind(journal)
        let restored = try await store.completeTranscriptRewind(sessionID: session.id)
        #expect(restored == "An existing draft\n\n" + delivery.body)
        #expect(try await store.messages(sessionID: session.id).map(\.seq) == [0])
        #expect(try await store.delivery(id: delivery.id)?.state == .accepted)
        #expect(try await store.pendingDeliveries(sessionID: session.id).isEmpty)
        #expect(try await store.turnCheckpoints(sessionID: session.id).isEmpty)
        #expect(try await store.retiredRewindCheckpoints(sessionID: session.id).map(\.id) == [checkpoint.id])
        let repeated = try await store.completeTranscriptRewind(sessionID: session.id)
        #expect(repeated == restored)
        let reopened = try Store(path: path)
        #expect(try await reopened.draft(sessionID: session.id) == restored)
        let backup = try #require(await reopened.transcriptRewindBackup(sessionID: session.id))
        #expect(backup.messages.count == 2)
        #expect(backup.prompt == delivery.body)
    }

    @Test("Unconfirmed provider history cannot delete rows or close the recovery conversation")
    func unconfirmed() async throws {
        let store = try makeTestStore("rewind-unconfirmed")
        let (session, _, checkpoint) = try await fixture(store)
        _ = try await store.prepareTranscriptRewind(checkpoint)
        try await store.saveCheckpointRewind(CheckpointRewind(checkpoint: checkpoint, recovery: nil, restoringFiles: false))
        await #expect(throws: SnapshotFailure.self) { try await store.completeTranscriptRewind(sessionID: session.id) }
        await #expect(throws: SnapshotFailure.self) { try await store.deleteSession(id: session.id) }
        await #expect(throws: SnapshotFailure.self) {
            _ = try await store.update(sessionID: session.id) { $0.archivedAt = Date() }
        }
        #expect(try await store.messages(sessionID: session.id).count == 3)
        let workspaceID = try #require(session.workspaceID)
        #expect(try await store.pendingCheckpointRewind(workspaceID: workspaceID)?.checkpoint.id == checkpoint.id)
    }
}
