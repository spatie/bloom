import Testing
import Foundation
@testable import BloomCore

/// What Claude Code 2.1.322 sent with a turn refused on 12 November 2026, the org's monthly extra
/// usage budget already spent.
private let orgSpent = Data(#"""
{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1794319200,"rateLimitType":"five_hour","overageStatus":"rejected","overageDisabledReason":"org_level_disabled_until","isUsingOverage":false}}
"""#.utf8)

private let clock = ResetClock(
    now: Date(timeIntervalSince1970: 1_794_319_200 - 3600),
    timeZone: TimeZone(identifier: "UTC")!,
    locale: Locale(identifier: "en_GB")
)

@Suite("Which wall a turn ran into")
struct LimitHitTests {
    @Test func readsTheWindowTheResetAndWhyCreditsRefused() {
        let hit = LimitHit.read(rateLimitEvent: orgSpent)
        #expect(hit == LimitHit(
            window: "five_hour",
            resetsAt: Date(timeIntervalSince1970: 1_794_319_200),
            creditRefusal: "org_level_disabled_until"
        ))
    }

    /// The session window leads, the spent budget follows, which is the reverse of the CLI.
    @Test func saysTheSessionLimitBeforeTheMonthlyBudget() {
        let lead = LimitHit.read(rateLimitEvent: orgSpent)?.lead(clock: clock)
        #expect(lead == "The 5-hour session limit is reached, and the organisation's monthly extra usage "
            + "budget is spent, so nothing more can run until it resets at 14:00. Nothing is lost, "
            + "and the chat can pick up where it stopped.")
    }

    /// With the event the lead is the hit's own; without it, the generic sentence stays.
    @Test func leadsTheFailureWithTheHitWhenOneWasKept() throws {
        let line = #"{"type":"result","subtype":"success","is_error":true,"api_error_status":429,"result":"You've hit your org's monthly spend limit","session_id":"s"}"#
        guard case .result(let result)? = AgentEvent.decode(line: line) else {
            Issue.record("not a result")
            return
        }
        let hit = try #require(LimitHit.read(rateLimitEvent: orgSpent))
        #expect(TurnFailure.of(result, limitHit: hit)?.lead == hit.lead())
        #expect(TurnFailure.of(result)?.lead == TurnFailure.limitLead)
    }

    /// A reading on the way up is not the wall.
    @Test func ignoresAnAllowedEvent() {
        let allowed = Data(#"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","rateLimitType":"five_hour","utilization":0.9}}"#.utf8)
        #expect(LimitHit.read(rateLimitEvent: allowed) == nil)
    }

    /// Walked back from the result, it stops at the user row that opened the turn, so an older
    /// turn's wall is never borrowed.
    @Test func findsOnlyTheClosingTurnsHit() {
        let reply = Data(#"{"type":"assistant"}"#.utf8)
        let mine: [(kind: MessageKind, payload: Data)] = [(.assistantText, reply), (.notice, orgSpent)]
        #expect(LimitHit.latest(walkingBack: mine)?.window == "five_hour")

        let older: [(kind: MessageKind, payload: Data)] = [(.assistantText, reply), (.user, reply), (.notice, orgSpent)]
        #expect(LimitHit.latest(walkingBack: older) == nil)
    }
}
