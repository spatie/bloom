import Testing
import Foundation
@testable import BloomCore

/// A fixed instant, because every assertion here is about a reset that has or has not passed.
private let hit = Date(timeIntervalSince1970: 1_789_760_000)
private let reset = hit.addingTimeInterval(3 * 3600)

private func quota(
    _ key: String = "five_hour",
    provider: AgentKind = .claudeCode,
    fraction: Double?,
    resetsAt: Date? = reset,
    observedAt: Date
) -> AgentQuota {
    AgentQuota(
        provider: provider,
        window: .named(key),
        measure: fraction.map { .fraction($0) } ?? .unknown,
        resetsAt: resetsAt,
        observedAt: observedAt
    )
}

private func result(_ line: String) throws -> AgentResult {
    guard case .result(let result)? = AgentEvent.decode(line: line) else {
        Issue.record("not a result: \(line)")
        throw CancellationError()
    }
    return result
}

@Suite("Continuing after a limit resets")
struct LimitResumeTests {
    /// The shape Claude Code's `result` line takes when a turn ends on the allowance, put together
    /// from what 2.1.276 wrote to its own session file for the same turn and from the CLI's result
    /// builder, which copies `api_error_status` onto a result whose subtype is still `success`.
    @Test func recognisesClaudeCodeHittingItsLimit() throws {
        let line = """
        {"type":"result","subtype":"success","is_error":true,"api_error_status":429,\
        "result":"You've hit your session limit · resets 11:40pm (Europe/Brussels)",\
        "duration_ms":812,"num_turns":1,"session_id":"s"}
        """
        #expect(LimitResume.isLimitHit(try result(line)))
        #expect(TurnFailure.of(try result(line))?.lead == TurnFailure.limitLead)
    }

    /// Any other failure is not the wall, and neither is a success that happens to mention one.
    @Test func leavesOtherFailuresAlone() throws {
        let died = """
        {"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error",\
        "result":"API Error: Connection lost mid-response.","session_id":"s"}
        """
        let fine = """
        {"type":"result","subtype":"success","is_error":false,"api_error_status":429,\
        "result":"done","session_id":"s"}
        """
        #expect(!LimitResume.isLimitHit(try result(died)))
        #expect(!LimitResume.isLimitHit(try result(fine)))
    }

    /// The transcript asks with the line it already holds parsed, and must get the same answer.
    @Test func answersTheSameFromAParsedLine() throws {
        let lines = [
            #"{"type":"result","subtype":"success","is_error":true,"api_error_status":429,"result":"limit","session_id":"s"}"#,
            #"{"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error","result":"lost","session_id":"s"}"#,
            #"{"type":"result","subtype":"error_during_execution","is_error":true,"codex_error_info":"usageLimitExceeded","session_id":"s"}"#,
        ]
        for line in lines {
            let parsed = try #require(JSONValue.parse(Data(line.utf8)))
            #expect(LimitResume.isLimitHit(line: parsed) == LimitResume.isLimitHit(try result(line)))
        }
    }

    /// A limit hit arms the resume by itself, once: the continuation hitting the wall again gets
    /// the button, so a 429 with no window to wait on cannot resend at every reading.
    @Test func armsByItselfOncePerWall() throws {
        let line = """
        {"type":"result","subtype":"success","is_error":true,"api_error_status":429,\
        "result":"You've hit your session limit","session_id":"s"}
        """
        let died = """
        {"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error",\
        "result":"API Error: Connection lost mid-response.","session_id":"s"}
        """
        #expect(LimitResume.armsByItself(after: try result(line), wasResumeTurn: false))
        #expect(!LimitResume.armsByItself(after: try result(line), wasResumeTurn: true))
        #expect(!LimitResume.armsByItself(after: try result(died), wasResumeTurn: false))
    }

    /// Codex says it as a token on the failed turn, and the translation keeps it on the stored row.
    @Test func recognisesCodexHittingItsLimit() throws {
        let error = JSONValue.parse(#"{"message":"You've hit your usage limit.","codexErrorInfo":"usageLimitExceeded"}"#)
        #expect(CodexErrorInfo.token(in: error) == "usageLimitExceeded")
        let carrying = JSONValue.parse(#"{"codexErrorInfo":{"usageLimitExceeded":{"resetsAt":1}}}"#)
        #expect(CodexErrorInfo.token(in: carrying) == "usageLimitExceeded")

        var translation = CodexTranslation(context: CodexTranslation.Context(model: "gpt-5.6-sol"))
        let events = translation.translate(.turnCompleted(CodexTurn(
            id: "t", threadID: "th", status: .failed,
            errorMessage: "You've hit your usage limit.", errorInfo: "usageLimitExceeded"
        )))
        guard case .result(let failed)? = events.first else {
            Issue.record("expected a result")
            return
        }
        #expect(LimitResume.isLimitHit(failed))
    }

    /// The `rejected` event that comes with the wall is a spent window even with no figure in it,
    /// which is what gives the resume a reset time to wait for.
    @Test func readsARejectedEventAsSpent() {
        let line = Data(#"""
        {"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1789767600,"rateLimitType":"five_hour","overageStatus":"rejected","isUsingOverage":false}}
        """#.utf8)
        let quotas = AgentQuotaAdapters.quotas(fromRateLimitEvent: line, at: hit)
        #expect(quotas.first?.fraction == 1)
        #expect(quotas.first?.resetsAt == Date(timeIntervalSince1970: 1_789_767_600))
    }

    /// Before the reset, it waits for the reset, whatever else is known.
    @Test func waitsForTheStatedReset() {
        var resume = LimitResume(provider: .claudeCode, hitAt: hit)
        let quotas = [quota(fraction: 1, observedAt: hit)]
        let step = resume.step(quotas: quotas, at: hit.addingTimeInterval(60))
        #expect(step == .waitUntil(reset))
    }

    /// The reset alone is not enough. The spent row has expired and dropped out, but nothing has
    /// been read since, so it checks rather than sending into a window that may not have turned.
    @Test func checksAfterTheResetBeforeSending() {
        var resume = LimitResume(provider: .claudeCode, hitAt: hit)
        let before = [quota(fraction: 1, observedAt: hit)]
        _ = resume.step(quotas: before, at: hit.addingTimeInterval(60))

        let weekly = quota("seven_day", fraction: 0.6, resetsAt: reset.addingTimeInterval(86_400 * 3),
                           observedAt: hit.addingTimeInterval(120))
        let justAfter = resume.step(quotas: before + [weekly], at: reset.addingTimeInterval(5))
        #expect(justAfter == .checking)

        let fresh = quota(fraction: 0, resetsAt: reset.addingTimeInterval(5 * 3600),
                          observedAt: reset.addingTimeInterval(30))
        let afterReading = resume.step(quotas: [weekly, fresh], at: reset.addingTimeInterval(40))
        #expect(afterReading == .go)
    }

    /// A reading after the reset that is still spent keeps it waiting, on the new reset.
    @Test func keepsWaitingWhenAnotherWindowIsSpent() {
        var resume = LimitResume(provider: .claudeCode, hitAt: hit)
        let weeklyReset = reset.addingTimeInterval(86_400)
        let quotas = [
            quota(fraction: 1, observedAt: hit),
            quota("seven_day", fraction: 1, resetsAt: weeklyReset, observedAt: hit),
        ]
        let step = resume.step(quotas: quotas, at: hit.addingTimeInterval(60))
        #expect(step == .waitUntil(weeklyReset))
    }

    /// A spent credit balance has no reset and is no longer restated once the org disables it. It
    /// must not hold the resume after the session window turns over, nor release it before.
    @Test func ignoresASpentCreditBalance() {
        var resume = LimitResume(provider: .claudeCode, hitAt: hit)
        let credits = AgentQuota(
            provider: .claudeCode, window: .extraUsage,
            measure: .counted(used: 500, limit: 500, unit: "EUR"),
            resetsAt: nil, observedAt: hit.addingTimeInterval(-86_400)
        )
        let session = quota(fraction: 1, observedAt: hit)
        let before = resume.step(quotas: [credits, session], at: hit.addingTimeInterval(60))
        #expect(before == .waitUntil(reset))

        let weekly = quota("seven_day", fraction: 0.4, resetsAt: reset.addingTimeInterval(86_400 * 3),
                           observedAt: reset.addingTimeInterval(30))
        let after = resume.step(quotas: [credits, session, weekly], at: reset.addingTimeInterval(40))
        #expect(after == .go)
    }

    /// With no reset stated anywhere, it needs a reading from after the hit showing room.
    @Test func withNoResetKnownItWaitsForAReadingAfterTheHit() {
        var resume = LimitResume(provider: .claudeCode, hitAt: hit)
        let stale = [quota(fraction: 0.4, observedAt: hit.addingTimeInterval(-600))]
        let before = resume.step(quotas: stale, at: hit.addingTimeInterval(60))
        #expect(before == .checking)

        let fresh = [quota(fraction: 0.02, observedAt: hit.addingTimeInterval(90))]
        let after = resume.step(quotas: fresh, at: hit.addingTimeInterval(100))
        #expect(after == .go)
    }

    /// Another provider's readings say nothing about this one's allowance.
    @Test func ignoresOtherProviders() {
        var resume = LimitResume(provider: .claudeCode, hitAt: hit)
        let codex = [quota("primary", provider: .codex, fraction: 0.1, observedAt: hit.addingTimeInterval(90))]
        let step = resume.step(quotas: codex, at: hit.addingTimeInterval(100))
        #expect(step == .checking)
    }

    @Test func saysWhenItWillContinue() {
        let utc = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_GB")
        let at = Date(timeIntervalSince1970: 1_789_767_600)
        let sameDay = at.addingTimeInterval(-3600)
        #expect(LimitResume.Step.waitUntil(at).sentence(clock: ResetClock(now: sameDay, timeZone: utc, locale: locale))
            == "Continues after the limit resets at 21:40.")
    }

    /// A weekly reset days away names its day, so the time cannot pass for one already gone.
    @Test func namesTheDayOfAResetOnAnotherDay() {
        let utc = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_GB")
        let at = Date(timeIntervalSince1970: 1_789_767_600)
        let daysBefore = at.addingTimeInterval(-3 * 86_400)
        let sentence = LimitResume.Step.waitUntil(at).sentence(
            clock: ResetClock(now: daysBefore, timeZone: utc, locale: locale)
        )
        #expect(sentence.hasPrefix("Continues after the limit resets on "))
        #expect(sentence.hasSuffix(" at 21:40."))
    }
}
