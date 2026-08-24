import Testing
import Foundation
@testable import BloomCore

/// A fixed instant, for the reason `AgentQuotaTests` gives: half of what is asserted here is about
/// how old something is, and `Date()` would make it true only in the hour it was written.
private let now = Date(timeIntervalSince1970: 1_787_500_000)

private func quota(
    _ provider: AgentKind = .codex,
    _ window: QuotaWindow,
    _ measure: QuotaMeasure,
    resetsAt: Date? = nil,
    observedAt: Date = now
) -> AgentQuota {
    AgentQuota(
        provider: provider,
        window: window,
        measure: measure,
        resetsAt: resetsAt,
        observedAt: observedAt
    )
}

// MARK: - The delta

/// Codex's own schema calls `account/rateLimits/updated` a "Sparse rolling rate-limit update" and
/// tells clients to "merge available values into the most recent `account/rateLimits/read`
/// response", adding that a nullable field "does not clear a previously observed value". Bloom
/// read it as the whole truth. These are the three ways that went wrong.
@Suite("Quota merge")
struct QuotaMergeTests {
    private let week = QuotaWindow.lasting(604_800, key: "primary")
    private let reset = Date(timeIntervalSince1970: 1_787_986_128)

    /// The first way: a delta that restates the percentage and not the reset time used to write
    /// the reset time away, and a window with no reset time has no countdown and can never be
    /// recognised as turned over.
    @Test func keepsAResetTimeADeltaDidNotRestate() {
        let known = quota(.codex, week, .fraction(0.06), resetsAt: reset)
        let delta = quota(.codex, week, .fraction(0.11), resetsAt: nil, observedAt: now + 60)

        let merged = QuotaMerge.resolve(delta, against: known)

        #expect(merged.resetsAt == reset)
        #expect(merged.fraction == 0.11)
    }

    /// The second: everything on Codex's window is nullable except the percentage, so a delta can
    /// arrive with no length at all. It used to be declined outright, which threw away the one
    /// number the panel exists to show.
    @Test func putsBackALengthADeltaDidNotRestate() {
        let known = quota(.codex, week, .fraction(0.06), resetsAt: reset)
        let bare = quota(
            .codex,
            QuotaWindow(key: "primary", label: "Primary"),
            .fraction(0.42),
            resetsAt: reset,
            observedAt: now + 60
        )

        let merged = QuotaMerge.resolve(bare, against: known)

        #expect(merged.window.duration == 604_800)
        #expect(merged.window.label == "Week")
        #expect(merged.fraction == 0.42)
    }

    /// The third, and the one Claude Code hits rather than Codex: its `rate_limit_event` carries
    /// no `utilization` below the warning threshold, so a turn after the number is known used to
    /// take it back to nothing and the panel fell to "not reported" having once known better.
    @Test func keepsAFigureAReportDidNotRestate() {
        let known = quota(.claudeCode, .named("five_hour"), .fraction(0.77), resetsAt: reset)
        let silent = quota(
            .claudeCode,
            .named("five_hour"),
            .unknown,
            resetsAt: reset,
            observedAt: now + 60
        )

        #expect(QuotaMerge.resolve(silent, against: known).fraction == 0.77)
    }

    /// And the limit of all three, which is the assertion that keeps this honest. A different
    /// reset time means the window turned over, so a figure measured against the old one is a
    /// measurement of something that no longer exists and none of it carries.
    @Test func carriesNothingAcrossAWindowThatTurnedOver() {
        let known = quota(.codex, week, .fraction(0.94), resetsAt: reset)
        let after = quota(
            .codex,
            QuotaWindow(key: "primary", label: "Primary"),
            .unknown,
            resetsAt: reset + 604_800,
            observedAt: now + 60
        )

        let merged = QuotaMerge.resolve(after, against: known)

        #expect(merged.fraction == nil)
        #expect(merged.window.duration == nil)
        #expect(merged.resetsAt == reset + 604_800)
    }

    /// A late answer is not a later reading. Two askers can be in flight at once, so the one that
    /// comes back second is dropped rather than merged.
    @Test func dropsAReportOlderThanWhatIsOnFile() {
        let known = quota(.codex, week, .fraction(0.5), resetsAt: reset)
        let stale = quota(.codex, week, .fraction(0.1), resetsAt: reset, observedAt: now - 300)

        #expect(QuotaMerge.resolve(stale, against: known).fraction == 0.5)
    }

    @Test func takesAWindowNobodyHasSeenAsItStands() {
        let fresh = quota(.codex, week, .fraction(0.2), resetsAt: reset)
        #expect(QuotaMerge.resolve(fresh, against: nil) == fresh)
    }

    /// `merged` answers what Bloom knows; `resolved` answers what is worth writing. The difference
    /// matters because writing an untouched row back would restamp its age.
    @Test func keepsRowsNobodyMentionedOutOfTheWrite() {
        let claude = quota(.claudeCode, .named("five_hour"), .fraction(0.3), resetsAt: reset)
        let codex = quota(.codex, week, .fraction(0.06), resetsAt: reset)
        let report = [quota(.codex, week, .fraction(0.09), resetsAt: reset, observedAt: now + 60)]

        #expect(QuotaMerge.merged([claude, codex], with: report).count == 2)
        let written = QuotaMerge.resolved(report, against: [claude, codex])
        #expect(written.count == 1)
        #expect(written[0].provider == .codex)
    }
}

// MARK: - Freshness

@Suite("Quota freshness")
struct QuotaFreshnessTests {
    @Test func saysNothingAboutAFigureWithinAPollOrTwo() {
        #expect(QuotaFreshness.of(now - QuotaPollSchedule.interval, at: now) == .current)
        #expect(QuotaFreshness.of(now - QuotaPollSchedule.interval, at: now).phrase == nil)
    }

    @Test func saysHowOldAFigureIsOnceAPollHasBeenMissed() {
        #expect(QuotaFreshness.of(now - 5400, at: now).phrase == "an hour ago")
        #expect(QuotaFreshness.of(now - 10_800, at: now).phrase == "3 hours ago")
        #expect(QuotaFreshness.of(now - 2400, at: now).phrase == "40 min ago")
        #expect(QuotaFreshness.of(now - 172_800, at: now).phrase == "2 days ago")
    }

    /// The oldest row is the one the panel has to answer for: a board is only as current as the
    /// staleset thing on it.
    @Test func answersForTheOldestRowOnTheBoard() {
        let board = QuotaBoard.make(
            from: [
                quota(.claudeCode, .named("five_hour"), .fraction(0.3), observedAt: now - 60),
                quota(.codex, .lasting(604_800, key: "primary"), .fraction(0.1), observedAt: now - 7200),
            ],
            at: now
        )
        #expect(QuotaFreshness.of(board, at: now).phrase == "2 hours ago")
    }

    @Test func hasNothingToSayAboutAnEmptyBoard() {
        #expect(QuotaFreshness.of(QuotaBoard.make(from: [], at: now), at: now) == .current)
    }
}

// MARK: - The schedule

@Suite("Quota poll schedule")
struct QuotaPollScheduleTests {
    @Test func asksWhenItNeverHas() {
        #expect(QuotaPollSchedule.isDue(lastAskedAt: nil, at: now, after: QuotaPollSchedule.interval))
    }

    @Test func declinesUntilTheGapHasPassed() {
        let last = now - 60
        #expect(!QuotaPollSchedule.isDue(lastAskedAt: last, at: now, after: QuotaPollSchedule.onDemandFloor))
        #expect(QuotaPollSchedule.isDue(lastAskedAt: now - 300, at: now, after: QuotaPollSchedule.onDemandFloor))
    }

    /// The menu may ask sooner than the background poll, and never as often as it is opened.
    @Test func letsTheMenuAskSoonerThanTheBackgroundPoll() {
        #expect(QuotaPollSchedule.onDemandFloor < QuotaPollSchedule.interval)
        #expect(QuotaPollSchedule.onDemandFloor > 0)
    }

    /// Ten minutes against a five hour window is 3.3 percent of the tightest allowance either
    /// provider publishes, and the panel draws whole percentages.
    @Test func staysWellInsideTheShortestWindowEitherProviderPublishes() {
        #expect(QuotaPollSchedule.interval / 18_000 < 0.05)
    }
}

// MARK: - The wire

/// The request Bloom writes and the answer it reads back, both asserted against what the real
/// binaries produced rather than against a schema.
@Suite("Quota sources")
struct QuotaSourceTests {
    @Test func writesTheControlRequestClaudeCodeAnswers() {
        let line = ClaudeCodeQuotaSource.request(id: "bloom-usage-1")
        let json = JSONValue.parse(line)

        #expect(json?["type"]?.stringValue == "control_request")
        #expect(json?["request_id"]?.stringValue == "bloom-usage-1")
        #expect(json?["request"]?["subtype"]?.stringValue == "get_usage")
        #expect(!line.contains("\n"))
    }

    /// Recorded off claude 2.1.241 on this machine, in full. The nesting is the CLI's own: the
    /// outer `response` is the control channel's result and the inner one is the handler's.
    private static let answer = """
    {"type":"control_response","response":{"subtype":"success","request_id":"u1","response":\
    {"session":{"total_cost_usd":0,"total_api_duration_ms":0,"total_duration_ms":326,\
    "total_lines_added":0,"total_lines_removed":0,"model_usage":{}},"subscription_type":null,\
    "rate_limits_available":false,"rate_limits":null,"behaviors":null}}}
    """

    @Test func readsTheAnswerToItsOwnRequestAndNobodyElses() {
        #expect(ClaudeCodeQuotaSource.answer(in: Self.answer, to: "u1") != nil)
        #expect(ClaudeCodeQuotaSource.answer(in: Self.answer, to: "u2") == nil)
        #expect(ClaudeCodeQuotaSource.answer(in: "not json at all", to: "u1") == nil)
    }

    /// `total_cost_usd` and `total_api_duration_ms` are zero in the recorded answer, which is the
    /// evidence for the one rule this whole feature rests on: asking does not run a turn.
    @Test func asksSomethingThatCostsNothing() throws {
        let payload = try #require(ClaudeCodeQuotaSource.answer(in: Self.answer, to: "u1"))
        let json = try #require(JSONValue.parse(payload))

        #expect(json["session"]?["total_cost_usd"]?.doubleValue == 0)
        #expect(json["session"]?["total_api_duration_ms"]?.doubleValue == 0)
    }

    /// The CLI refuses `-p --output-format stream-json` without `--verbose`, and nothing else in
    /// the invocation may state a model, a mode or a settings file, because nothing here runs a
    /// turn and a flag that is not sent cannot override something the user chose.
    @Test func spawnsTheSmallestInvocationTheCLIAccepts() {
        #expect(ClaudeCodeQuotaSource.arguments.contains("--verbose"))
        #expect(ClaudeCodeQuotaSource.arguments.contains("--input-format"))
        #expect(!ClaudeCodeQuotaSource.arguments.contains("--model"))
        #expect(!ClaudeCodeQuotaSource.arguments.contains("--settings"))
        #expect(!ClaudeCodeQuotaSource.arguments.contains("--permission-prompt-tool"))
    }

    @Test func asksCodexOnItsStableSurface() {
        #expect(CodexQuotaSource.method == "account/rateLimits/read")
    }
}

// MARK: - The answers, decoded

/// Both adapters, against payloads recorded off the real binaries rather than written from a
/// schema. A feature that is entirely a claim about what a CLI returns is worth nothing asserted
/// against a claim.
@Suite("Requested quota payloads")
struct RequestedQuotaPayloadTests {
    /// Claude Code 2.1.241, with every window the CLI's own schema names. The account this was
    /// shaped from reports `five_hour` and `seven_day` on the notification path; `get_usage`
    /// returns the other three as well, which is the whole reason for asking.
    private static let usage = """
    {"session":{"total_cost_usd":0,"total_api_duration_ms":0,"total_duration_ms":326,\
    "total_lines_added":0,"total_lines_removed":0,"model_usage":{}},"subscription_type":"max",\
    "rate_limits_available":true,"rate_limits":{\
    "five_hour":{"utilization":42,"resets_at":"2026-08-24T02:30:00Z"},\
    "seven_day":{"utilization":77.5,"resets_at":"2026-08-27T09:00:00Z"},\
    "seven_day_opus":{"utilization":null,"resets_at":"2026-08-27T09:00:00Z"},\
    "seven_day_sonnet":{"utilization":3,"resets_at":"2026-08-27T09:00:00Z"},\
    "extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null,"utilization":null}},\
    "behaviors":null}
    """

    @Test func readsEveryWindowClaudeCodeAnswersWith() throws {
        let quotas = AgentQuotaAdapters.quotas(fromRateLimitEvent: Data(Self.usage.utf8), at: now)
        let byKey = Dictionary(quotas.map { ($0.window.key, $0) }, uniquingKeysWith: { first, _ in first })

        #expect(quotas.count == 4)
        #expect(quotas.allSatisfy { $0.provider == .claudeCode })
        // A percentage on this wire, where the notification sends a fraction. Getting this the
        // wrong way round would draw a five hour window at 4200 percent.
        #expect(byKey["five_hour"]?.fraction == 0.42)
        #expect(byKey["seven_day"]?.fraction == 0.775)
        // An ISO 8601 string here, where the notification sends unix seconds.
        #expect(byKey["five_hour"]?.resetsAt == ISO8601DateFormatter().date(from: "2026-08-24T02:30:00Z"))
    }

    /// A window the account has but has not used yet is `.unknown`, never zero, exactly as it is
    /// on the notification path. This is the "not reported" the feature keeps rather than removes.
    @Test func keepsAWindowNobodyMeasuredAsUnmeasured() throws {
        let quotas = AgentQuotaAdapters.quotas(fromRateLimitEvent: Data(Self.usage.utf8), at: now)
        let opus = try #require(quotas.first { $0.window.key == "seven_day_opus" })

        #expect(opus.measure == .unknown)
        #expect(opus.fraction == nil)
        // And it is still a readable row rather than a raw token, with the length read off the
        // front of the name and the rest kept beside it.
        #expect(opus.window.duration == 604_800)
        #expect(opus.window.label == "Week (opus)")
    }

    /// **The account the panel was rebuilt for, answered on 24 August 2026.** Every field below is
    /// what the CLI actually returned, trimmed of the parts nothing reads. It is here because it
    /// answers the question the whole redesign started from: why does the panel show three rows?
    ///
    /// Because `seven_day_opus`, `seven_day_sonnet` and `seven_day_oauth_apps` came back as JSON
    /// null, which `JSONValue`'s subscript reads as a missing key. That is right: a null window is
    /// one the plan does not have. Nothing was being dropped that had been reported, with one
    /// exception, and it was the important one.
    private static let maxAccount = """
    {"session":{"total_cost_usd":0},"subscription_type":"max","rate_limits_available":true,    "rate_limits":{    "five_hour":{"utilization":4,"resets_at":"2026-08-24T10:20:00.415000+00:00"},    "seven_day":{"utilization":60,"resets_at":"2026-08-28T03:00:00.415023+00:00"},    "seven_day_oauth_apps":null,"seven_day_opus":null,"seven_day_sonnet":null,    "extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null,    "utilization":null,"currency":null},    "model_scoped":[{"display_name":"Fable","utilization":71,    "resets_at":"2026-08-28T03:00:00.415206+00:00"}]}}
    """

    @Test func readsTheModelScopedWeeklyThatWasBeingThrownAway() throws {
        let quotas = AgentQuotaAdapters.quotas(fromRateLimitEvent: Data(Self.maxAccount.utf8), at: now)
        let byKey = Dictionary(quotas.map { ($0.window.key, $0) }, uniquingKeysWith: { first, _ in first })

        // Three rows, not two: a null window produces none, and the model scoped weekly produces
        // one. Before this it produced none either, and the panel led with 60 percent while the
        // wall the account would actually hit stood at 71.
        #expect(quotas.count == 3)
        #expect(byKey["seven_day"]?.fraction == 0.6)
        #expect(byKey["seven_day_model_fable"]?.fraction == 0.71)
        // A week, and it has to be, or the row cannot be sorted or paced.
        #expect(byKey["seven_day_model_fable"]?.window.duration == 604_800)
        // The provider's own spelling of its own product, capitals and all.
        #expect(byKey["seven_day_model_fable"]?.window.label == "Week (Fable)")
    }

    /// A null window is one the plan does not have, which is not the same as one it has and has
    /// not measured. It produces no row at all, and that is why this account shows two Claude
    /// windows rather than five.
    @Test func producesNoRowForAWindowThePlanDoesNotHave() {
        let quotas = AgentQuotaAdapters.quotas(fromRateLimitEvent: Data(Self.maxAccount.utf8), at: now)
        #expect(!quotas.contains { $0.window.key.contains("opus") })
        #expect(!quotas.contains { $0.window.key.contains("oauth") })
    }

    /// Extra usage switched off comes with a null limit, null credits and a null utilization. A
    /// row saying nothing about nothing is worse than no row.
    @Test func showsNoExtraUsageRowUntilTheAccountHasItSwitchedOn() {
        let quotas = AgentQuotaAdapters.quotas(fromRateLimitEvent: Data(Self.maxAccount.utf8), at: now)
        #expect(!quotas.contains { $0.window.key == "extra_usage" })
    }

    /// And when it is switched on it is a row, because it is the wall that comes after the windows
    /// and it is money. The amounts rather than the percentage, because "$17.20 of $50.00" is a
    /// thing somebody can act on.
    @Test func readsExtraUsageAsMoneyOnceItIsSwitchedOn() throws {
        let enabled = """
        {"rate_limits_available":true,"rate_limits":{\
        "extra_usage":{"is_enabled":true,"monthly_limit":50,"used_credits":17.2,\
        "utilization":34.4,"currency":"USD"}}}
        """
        let quotas = AgentQuotaAdapters.quotas(fromRateLimitEvent: Data(enabled.utf8), at: now)
        let extra = try #require(quotas.first { $0.window.key == "extra_usage" })

        #expect(extra.measure == .counted(used: 17.2, limit: 50, unit: "USD"))
        #expect(extra.fraction == 0.344)
        // No reset time and no length, which is true rather than missing: it is a balance against
        // a monthly ceiling and the provider states neither a turnover instant nor a window.
        #expect(extra.resetsAt == nil)
        #expect(extra.window.duration == nil)
    }

    /// A display name is not a key. Two spellings of one model must not become two rows for one
    /// window the first time the provider restyles its own labels.
    @Test func makesOneStableKeyOutOfAModelsDisplayName() {
        #expect(ClaudeCodeUsageAdapter.slug("Claude Opus 4.5") == "claude_opus_4_5")
        #expect(ClaudeCodeUsageAdapter.slug("Fable") == "fable")
    }

    /// An API key, Bedrock or Vertex session has no plan limits to report. That is not an error
    /// and not a zero: no rows, nothing written, and the panel keeps saying nothing.
    @Test func writesNothingForAnAccountWithNoPlanLimits() {
        let none = """
        {"session":{"total_cost_usd":0},"subscription_type":null,\
        "rate_limits_available":false,"rate_limits":null,"behaviors":null}
        """
        #expect(AgentQuotaAdapters.quotas(fromRateLimitEvent: Data(none.utf8), at: now).isEmpty)
    }

    /// Recorded off codex-cli 0.147.0 on this machine, answering `account/rateLimits/read` on a
    /// connection that had started no thread.
    @Test func readsCodexsFullSnapshot() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/codex-rate-limits-read.json")
        let data = try Data(contentsOf: url)
        // The source hands `result` through, which is where the snapshot sits.
        let result = try #require(JSONValue.parse(data)?["result"])
        let payload = try JSONEncoder().encode(result)

        let quotas = AgentQuotaAdapters.quotas(fromRateLimitEvent: payload, at: now)

        #expect(quotas.count == 1)
        #expect(quotas[0].provider == .codex)
        #expect(quotas[0].window.key == "primary")
        #expect(quotas[0].window.duration == 604_800)
        #expect(quotas[0].fraction == 0)
        #expect(quotas[0].resetsAt == Date(timeIntervalSince1970: 1_787_986_128))
    }

    /// The sparse case, and the reason `CodexQuotaAdapter` no longer requires a length. Only
    /// `usedPercent` is required on Codex's own `RateLimitWindow`, so this is a legal rolling
    /// update and it used to produce nothing at all.
    @Test func readsARollingUpdateCarryingNothingButAPercentage() throws {
        let delta = """
        {"rateLimits":{"limitId":"codex","primary":{"usedPercent":37},"secondary":null}}
        """
        let quotas = AgentQuotaAdapters.quotas(fromRateLimitEvent: Data(delta.utf8), at: now)

        #expect(quotas.count == 1)
        #expect(quotas[0].fraction == 0.37)
        #expect(quotas[0].window.duration == nil)
        #expect(quotas[0].resetsAt == nil)
    }

    /// And the two halves together, which is the bug end to end: a full snapshot, then a rolling
    /// update carrying only the percentage, and the row still knows its length and its reset time.
    @Test func mergesARollingUpdateOntoTheSnapshotBeforeIt() throws {
        let snapshot = """
        {"rateLimits":{"primary":{"usedPercent":6,"windowDurationMins":10080,"resetsAt":1787986128}}}
        """
        let delta = """
        {"rateLimits":{"primary":{"usedPercent":37}}}
        """
        let known = AgentQuotaAdapters.quotas(fromRateLimitEvent: Data(snapshot.utf8), at: now)
        let reported = AgentQuotaAdapters.quotas(fromRateLimitEvent: Data(delta.utf8), at: now + 300)

        let merged = try #require(QuotaMerge.resolved(reported, against: known).first)

        #expect(merged.fraction == 0.37)
        #expect(merged.window.duration == 604_800)
        #expect(merged.window.label == "Week")
        #expect(merged.resetsAt == Date(timeIntervalSince1970: 1_787_986_128))
    }
}
