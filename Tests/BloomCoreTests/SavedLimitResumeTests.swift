import Testing
import Foundation
@testable import BloomCore

private let hitAt = Date(timeIntervalSince1970: 1_789_760_000)
private let resetAt = hitAt.addingTimeInterval(3 * 3600)

private let refused = Data("""
{"type":"result","subtype":"success","is_error":true,"api_error_status":429,\
"result":"You've hit your session limit","session_id":"s"}
""".utf8)
private let finished = Data("""
{"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"s"}
""".utf8)
private let silent = Data(#"{"type":"system","subtype":"commands_changed","commands":[]}"#.utf8)
private let typed = Data(#"{"type":"user","message":{"role":"user","content":"go on"}}"#.utf8)

@Suite("Waiting on a limit across a relaunch")
struct SavedLimitResumeTests {
    @Test func roundTripsThroughTheSettingsTable() {
        let session = SessionID("chat-1")
        let saved = SavedLimitResume(hitAt: hitAt, notBefore: resetAt)
        let settings = [
            (key: SavedLimitResume.key(for: session), value: saved.value),
            (key: "limitResume.broken", value: "not json"),
            (key: "session.chat-1.implementationPermissionMode", value: "default"),
        ]
        let all = SavedLimitResume.all(in: settings)
        #expect(all.count == 1)
        #expect(all.first?.sessionID == session)
        #expect(all.first?.saved == saved)
    }

    /// The reset outlives the window row, so a reading stored before the quit cannot send.
    @Test func aRestoredResetStillWaitsForAReadingAfterIt() {
        var resume = LimitResume(provider: .claudeCode, hitAt: hitAt, notBefore: resetAt)
        let beforeTheReset = AgentQuota(
            provider: .claudeCode, window: .named("five_hour"), measure: .fraction(0.1),
            resetsAt: resetAt.addingTimeInterval(5 * 3600), observedAt: hitAt.addingTimeInterval(60)
        )
        let step = resume.step(quotas: [beforeTheReset], at: resetAt.addingTimeInterval(3600))
        #expect(step == .checking)
    }

    @Test func appliesWhileTheChatEndsOnTheRefusedTurn() {
        let rows: [(kind: MessageKind, payload: Data)] = [
            (.system, silent), (.notice, Data()), (.result, refused), (.user, typed),
        ]
        #expect(SavedLimitResume.stillApplies(walkingBack: rows))
    }

    @Test func noLongerAppliesOnceSomethingFollowed() {
        let answered: [(kind: MessageKind, payload: Data)] = [(.result, finished), (.result, refused)]
        let typedSince: [(kind: MessageKind, payload: Data)] = [(.user, typed), (.result, refused)]
        let empty: [(kind: MessageKind, payload: Data)] = []
        #expect(!SavedLimitResume.stillApplies(walkingBack: answered))
        #expect(!SavedLimitResume.stillApplies(walkingBack: typedSince))
        #expect(!SavedLimitResume.stillApplies(walkingBack: empty))
    }
}
