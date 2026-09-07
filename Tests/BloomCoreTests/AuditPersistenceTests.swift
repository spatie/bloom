import Foundation
import Testing
@testable import BloomCore

@Suite(.scratchDirectory)
struct AuditPersistenceTests {
    @Test func sqlitePreservesNulTextAndEmptyBlobs() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        let text = "before\0after 🌱"
        let row = try #require(db.query("SELECT ? AS text, ? AS blob, ? AS missing", [
            .text(text), .blob(Data()), .null,
        ]).first)
        #expect(row.string("text") == text)
        #expect(row.data("blob") == Data())
        #expect(row.data("missing") == nil)
    }

    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity, Double(Int64.max)])
    func unrepresentableIntegersDoNotTrap(_ value: Double) {
        #expect(SQLValue.double(value).intValue == nil)
        #expect(SQLValue.double(-1.9).intValue == -1)
    }

    @Test(arguments: [Int32(-1), Int32.max])
    func unsupportedSchemaIsNotRepaired(_ version: Int32) throws {
        let path = TestScratch.unique("schema.sqlite")
        let raw = try SQLiteDatabase(path: path)
        try raw.setUserVersion(version)
        #expect(throws: SQLiteError.self) { try Store(path: path) }
        #expect(try raw.readUserVersion() == version)
        #expect(try raw.query("SELECT name FROM sqlite_master WHERE type = 'table'").isEmpty)
    }

    @Test func aDeliveryHasOnlyOneClaimantAndDiscardWinsBeforeClaim() async throws {
        let store = try makeTestStore("claim")
        let session = try await store.upsert(AskConversation.newSession())
        let delivery = try await store.enqueueDelivery(Delivery(targetSessionID: session.id, body: "hello"))
        async let first = store.markDelivered(id: delivery.id)
        async let second = store.markDelivered(id: delivery.id)
        let results = try await [first, second]
        #expect(results.filter { $0 }.count == 1)
        let cancelledAfter = try await store.cancelDelivery(id: delivery.id)
        #expect(!cancelledAfter)
        let other = try await store.enqueueDelivery(Delivery(targetSessionID: session.id, body: "discard"))
        let cancelled = try await store.cancelDelivery(id: other.id)
        let claimed = try await store.markDelivered(id: other.id)
        #expect(cancelled)
        #expect(!claimed)
    }

    @Test func failedClaimLeavesTheMessagePending() async throws {
        let store = try makeTestStore("failed-claim")
        let session = try await store.upsert(AskConversation.newSession())
        let delivery = try await store.enqueueDelivery(Delivery(targetSessionID: session.id, body: "hello"))
        let raw = try SQLiteDatabase(path: store.path)
        try raw.execute("CREATE TRIGGER refuse_claim BEFORE UPDATE ON deliveries BEGIN SELECT RAISE(ABORT, 'disk full'); END")
        await #expect(throws: SQLiteError.self) { try await store.markDelivered(id: delivery.id) }
        #expect(try await store.pendingDeliveries(sessionID: session.id).map(\.id) == [delivery.id])
    }

    @Test(arguments: ["INSERT ON deliveries", "DELETE ON drafts"])
    func enqueueAndDraftClearRollBackTogether(_ write: String) async throws {
        let store = try makeTestStore("enqueue-rollback")
        let session = try await store.upsert(AskConversation.newSession())
        try await store.saveDraft(sessionID: session.id, body: "my draft")
        let raw = try SQLiteDatabase(path: store.path)
        try raw.execute("CREATE TRIGGER refuse_write BEFORE \(write) BEGIN SELECT RAISE(ABORT, 'disk full'); END")
        let delivery = Delivery(targetSessionID: session.id, body: "my draft")
        await #expect(throws: SQLiteError.self) {
            try await store.enqueueDelivery(delivery, clearingDraftMatching: "my draft")
        }
        #expect(try await store.draft(sessionID: session.id) == "my draft")
        #expect(try await store.pendingDeliveries(sessionID: session.id).isEmpty)
    }

    @Test func enqueueNeverClearsANewerOrUnrelatedDraft() async throws {
        let store = try makeTestStore("enqueue-draft")
        let session = try await store.upsert(AskConversation.newSession())
        try await store.saveDraft(sessionID: session.id, body: "newer")
        try await store.enqueueDelivery(Delivery(targetSessionID: session.id, body: "old"), clearingDraftMatching: "old")
        #expect(try await store.draft(sessionID: session.id) == "newer")
        try await store.enqueueDelivery(Delivery(targetSessionID: session.id, body: "merge"), clearingDraftMatching: nil)
        #expect(try await store.draft(sessionID: session.id) == "newer")
        try await store.enqueueDelivery(Delivery(targetSessionID: session.id, body: "newer"), clearingDraftMatching: "newer")
        #expect(try await store.draft(sessionID: session.id).isEmpty)
    }

    @Test(arguments: ["INSERT ON sessions", "INSERT ON settings", "INSERT ON drafts", "UPDATE ON sessions"])
    func freshConversationRollsBackEveryWrite(_ write: String) async throws {
        let store = try makeTestStore("ask-rollback")
        let session = try await store.upsert(AskConversation.newSession())
        try await store.saveDraft(sessionID: session.id, body: "original")
        let raw = try SQLiteDatabase(path: store.path)
        try raw.execute("CREATE TRIGGER refuse_write BEFORE \(write) BEGIN SELECT RAISE(ABORT, 'disk full'); END")
        await #expect(throws: SQLiteError.self) {
            try await store.replaceAskConversation(id: session.id, controls: ComposerControls(isFastMode: true), draft: "carried")
        }
        #expect(try await store.sessionsWithoutWorkspace().map(\.id) == [session.id])
        #expect(try await store.draft(sessionID: session.id) == "original")
        #expect(try raw.query("SELECT * FROM sessions").count == 1)
        #expect(try raw.query("SELECT * FROM settings WHERE key LIKE 'session.%'").isEmpty)
    }

    @Test func freshConversationCommitsOnceWithControlsAndDraft() async throws {
        let store = try makeTestStore("ask-replace")
        let session = try await store.upsert(AskConversation.newSession())
        let controls = ComposerControls(isFastMode: true)
        let next = try await store.replaceAskConversation(id: session.id, controls: controls, draft: "carried")
        #expect(try await store.session(id: session.id)?.archivedAt != nil)
        #expect(try await store.sessionsWithoutWorkspace().map(\.id) == [next.id])
        #expect(try await store.draft(sessionID: next.id) == "carried")
        #expect(try await store.setting(ComposerControls.fastModeKey(sessionID: next.id)) == "1")
        await #expect(throws: SQLiteError.self) {
            try await store.replaceAskConversation(id: session.id, controls: controls)
        }
    }

    @Test func overlappingDrainsCoalesceUntilTheOwnerFinishes() {
        var state = DeliveryDrainState.idle
        let first = state.begin()
        let second = state.begin()
        let third = state.begin()
        let again = state.finish()
        let next = state.begin()
        let finished = state.finish()
        #expect(first && !second && !third && again && next && !finished)
    }

    @Test func aFailedDrainDoesNotAutomaticallyRetryCoalescedSubmissions() {
        var state = DeliveryDrainState.idle
        let first = state.begin()
        let overlapping = state.begin()
        let repeatAfterFailure = state.finish(allowRepeat: false)
        let explicitRetry = state.begin()
        #expect(first && !overlapping && !repeatAfterFailure && explicitRetry)
    }
}
