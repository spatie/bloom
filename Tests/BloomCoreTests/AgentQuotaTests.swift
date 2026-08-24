import Testing
import Foundation
@testable import BloomCore

/// The reference clock for everything here. A fixed instant, because half of these assertions are
/// about a window that has or has not turned over and `Date()` would make them true only until the
/// hour it was written in.
private let now = Date(timeIntervalSince1970: 1_787_500_000)

@Suite("Agent quota model")
struct AgentQuotaModelTests {
    @Test func readsClaudeCodesWindowNames() {
        #expect(QuotaWindow.named("five_hour").duration == 18_000)
        #expect(QuotaWindow.named("five_hour").label == "5 hours")
        #expect(QuotaWindow.named("seven_day").duration == 604_800)
        #expect(QuotaWindow.named("seven_day").label == "Week")
    }

    /// The point of parsing the name rather than looking it up: a window nobody has shipped yet
    /// still arrives with a length and a readable label.
    @Test func readsWindowNamesNothingHasShippedYet() {
        #expect(QuotaWindow.named("one_day").label == "Day")
        #expect(QuotaWindow.named("30_days").duration == 2_592_000)
        #expect(QuotaWindow.named("one_month").label == "Month")
    }

    /// And a name that cannot be read is not an error. It loses its length and keeps its words.
    @Test func survivesAWindowNameItCannotRead() {
        let window = QuotaWindow.named("rolling_burst_allowance")
        #expect(window.duration == nil)
        #expect(window.label == "Rolling burst allowance")
        #expect(window.key == "rolling_burst_allowance")
    }

    @Test func labelsALengthTheWayAPersonWouldSayIt() {
        #expect(QuotaWindow.label(forSeconds: 604_800) == "Week")
        #expect(QuotaWindow.label(forSeconds: 1_209_600) == "2 weeks")
        #expect(QuotaWindow.label(forSeconds: 18_000) == "5 hours")
        #expect(QuotaWindow.label(forSeconds: 1800) == "30 min")
    }

    /// The three states of a measure are genuinely different, and the middle one is the reason the
    /// enum exists: a limit can be missing while the usage is known.
    @Test func keepsUsageAndLimitApart() {
        #expect(QuotaMeasure.fraction(0.77).fraction == 0.77)
        #expect(QuotaMeasure.counted(used: 40, limit: 200, unit: "requests").fraction == 0.2)
        #expect(QuotaMeasure.counted(used: 40, limit: nil, unit: "requests").fraction == nil)
        #expect(QuotaMeasure.counted(used: 40, limit: nil, unit: "requests").isKnown)
        #expect(QuotaMeasure.unknown.fraction == nil)
        #expect(!QuotaMeasure.unknown.isKnown)
    }

    @Test func gradesHowCloseAWindowIsToItsWall() {
        #expect(QuotaSeverity.of(nil) == .calm)
        #expect(QuotaSeverity.of(0.5) == .calm)
        #expect(QuotaSeverity.of(0.75) == .calm)
        #expect(QuotaSeverity.of(0.85) == .warning)
        #expect(QuotaSeverity.of(0.94) == .critical)
        #expect(QuotaSeverity.of(1) == .spent)
    }

    @Test func saysWhenAWindowLifts() {
        #expect(QuotaCountdown.phrase(until: now.addingTimeInterval(30), from: now) == "in under a minute")
        #expect(QuotaCountdown.phrase(until: now.addingTimeInterval(1500), from: now) == "in 25 min")
        #expect(QuotaCountdown.phrase(until: now.addingTimeInterval(8100), from: now) == "in 2h 15m")
        #expect(QuotaCountdown.phrase(until: now.addingTimeInterval(93_600), from: now) == "in 1d 2h")
        #expect(QuotaCountdown.phrase(until: now.addingTimeInterval(400_000), from: now) == "in 4d")
        #expect(QuotaCountdown.phrase(until: now.addingTimeInterval(-10), from: now) == "any moment now")
    }
}

@Suite("Quota board")
struct QuotaBoardTests {
    private func quota(
        _ provider: AgentKind,
        _ window: QuotaWindow,
        _ fraction: Double?,
        resets: TimeInterval = 3600
    ) -> AgentQuota {
        AgentQuota(
            provider: provider,
            window: window,
            measure: fraction.map { .fraction($0) } ?? .unknown,
            resetsAt: now.addingTimeInterval(resets),
            observedAt: now
        )
    }

    @Test func groupsByProviderAndPutsTheShortestWindowFirst() {
        let board = QuotaBoard.make(from: [
            quota(.codex, .lasting(604_800, key: "primary"), 0.06),
            quota(.claudeCode, .named("seven_day"), 0.77),
            quota(.claudeCode, .named("five_hour"), 0.42),
        ], at: now)

        #expect(board.providers.map(\.kind) == [.claudeCode, .codex])
        #expect(board.providers[0].quotas.map(\.window.label) == ["5 hours", "Week"])
    }

    /// The window nearest its wall, across every provider. Not what the panel puts first, which is
    /// each provider in turn shortest window first; this is what a one sentence summary names.
    @Test func namesTheNearestWall() {
        let board = QuotaBoard.make(from: [
            quota(.claudeCode, .named("five_hour"), 0.42),
            quota(.claudeCode, .named("seven_day"), 0.85),
            quota(.codex, .lasting(604_800, key: "primary"), 0.06),
        ], at: now)

        #expect(board.headline?.window.label == "Week")
        #expect(board.headline?.provider == .claudeCode)
        #expect(board.severity == .warning)
    }

    /// A window Claude has mentioned but not measured cannot be the headline, because the headline
    /// is meant to answer "how close am I" and that row has no answer.
    @Test func willNotLeadWithAWindowNobodyMeasured() {
        let board = QuotaBoard.make(from: [
            quota(.claudeCode, .named("five_hour"), nil),
            quota(.codex, .lasting(604_800, key: "primary"), 0.06),
        ], at: now)

        #expect(board.headline?.provider == .codex)
        #expect(board.all.count == 2)
    }

    /// The app was shut across a reset boundary. The stored percentage describes an allowance that
    /// has since been refilled, so it is not shown at all.
    @Test func dropsAWindowThatHasAlreadyTurnedOver() {
        let board = QuotaBoard.make(from: [
            quota(.claudeCode, .named("five_hour"), 0.94, resets: -60),
            quota(.claudeCode, .named("seven_day"), 0.30),
        ], at: now)

        #expect(board.all.map(\.window.key) == ["seven_day"])
    }

    /// Two of the four CLIs Bloom detects publish nothing. That is not an error and not an empty
    /// provider section, it is simply an absence.
    @Test func aProviderThatReportsNothingContributesNothing() {
        let board = QuotaBoard.make(from: [], at: now)
        #expect(board.isEmpty)
        #expect(board.headline == nil)
        #expect(board.severity == .calm)
    }
}

@Suite("Quota adapters")
struct AgentQuotaAdapterTests {
    private func fixture(_ index: Int) throws -> Data {
        let lines = try bloomFixtureLines("rate-limits.jsonl")
        return Data(lines[index].utf8)
    }

    /// Claude Code below its warning threshold: a window, a reset time, and no usage figure at
    /// all. Zero would be a lie the protocol never told.
    @Test func readsClaudeCodeWithNoUsageFigure() throws {
        let quotas = AgentQuotaAdapters.quotas(fromRateLimitEvent: try fixture(0), at: now)
        #expect(quotas.count == 1)
        #expect(quotas[0].provider == .claudeCode)
        #expect(quotas[0].window.key == "five_hour")
        #expect(quotas[0].window.label == "5 hours")
        #expect(quotas[0].measure == .unknown)
        #expect(quotas[0].resetsAt == Date(timeIntervalSince1970: 1_787_508_600))
    }

    @Test func readsClaudeCodePastItsWarningThreshold() throws {
        let quotas = AgentQuotaAdapters.quotas(fromRateLimitEvent: try fixture(1), at: now)
        #expect(quotas.count == 1)
        #expect(quotas[0].window.label == "Week")
        #expect(quotas[0].fraction == 0.77)
    }

    /// Codex, straight off the wire. `secondary` is null on this account and is skipped rather
    /// than stored as an empty window.
    @Test func readsCodexAndSkipsTheEmptySlot() throws {
        let quotas = AgentQuotaAdapters.quotas(fromRateLimitEvent: try fixture(2), at: now)
        #expect(quotas.count == 1)
        #expect(quotas[0].provider == .codex)
        #expect(quotas[0].window.key == "primary")
        #expect(quotas[0].window.label == "Week")
        #expect(quotas[0].fraction == 0.06)
    }

    /// The same payload once `CodexTranslation` has wrapped it, which is the shape the running app
    /// actually hands over.
    @Test func readsCodexThroughTheTranslationTheRunnerUses() throws {
        let raw = try fixture(2)
        let wrapped = CodexTranslation.rateLimitLine(raw)
        let quotas = AgentQuotaAdapters.quotas(fromRateLimitEvent: wrapped, at: now)
        #expect(quotas.map(\.fraction) == [0.06])
    }

    @Test func declinesALineThatIsNobodys() {
        let quotas = AgentQuotaAdapters.quotas(
            fromRateLimitEvent: Data(#"{"type":"rate_limit_event","something_new":{}}"#.utf8), at: now
        )
        #expect(quotas.isEmpty)
        #expect(AgentQuotaAdapters.quotas(fromRateLimitEvent: Data("not json".utf8), at: now).isEmpty)
    }
}

@Suite("Quota storage", .scratchDirectory)
struct AgentQuotaStoreTests {
    private func quota(
        _ provider: AgentKind,
        _ key: String,
        _ fraction: Double?,
        observed: Date = now,
        resets: TimeInterval = 3600
    ) -> AgentQuota {
        AgentQuota(
            provider: provider,
            window: .named(key),
            measure: fraction.map { .fraction($0) } ?? .unknown,
            resetsAt: now.addingTimeInterval(resets),
            observedAt: observed
        )
    }

    @Test func roundTripsEveryShapeOfMeasure() async throws {
        let store = try makeTestStore("quotas")
        try await store.recordQuotas([
            quota(.claudeCode, "five_hour", 0.42),
            quota(.claudeCode, "seven_day", nil),
            AgentQuota(
                provider: .codex,
                window: .lasting(604_800, key: "primary"),
                measure: .counted(used: 40, limit: nil, unit: "requests"),
                resetsAt: now.addingTimeInterval(7200),
                observedAt: now
            ),
        ])

        let stored = try await store.quotas(at: now).sorted { $0.id < $1.id }
        #expect(stored.count == 3)
        #expect(stored[0].measure == .fraction(0.42))
        #expect(stored[1].measure == .unknown)
        #expect(stored[2].measure == .counted(used: 40, limit: nil, unit: "requests"))
        #expect(stored[2].window.duration == 604_800)
    }

    /// Two workspaces on one account report the same window. It is one row, and the later
    /// observation is what is kept.
    @Test func twoWorkspacesReportingOneWindowIsOneRow() async throws {
        let store = try makeTestStore("quotas-shared")
        try await store.recordQuotas([quota(.claudeCode, "five_hour", 0.40)])
        try await store.recordQuotas([
            quota(.claudeCode, "five_hour", 0.55, observed: now.addingTimeInterval(10)),
        ])

        let stored = try await store.quotas(at: now)
        #expect(stored.count == 1)
        #expect(stored[0].fraction == 0.55)
    }

    /// The turns finish in whatever order two subprocesses happen to finish in, so a report that
    /// was already stale when it landed must not overwrite the fresher one beside it.
    @Test func aLateReportCannotOverwriteAFresherOne() async throws {
        let store = try makeTestStore("quotas-late")
        try await store.recordQuotas([
            quota(.claudeCode, "five_hour", 0.55, observed: now.addingTimeInterval(10)),
        ])
        try await store.recordQuotas([quota(.claudeCode, "five_hour", 0.40)])

        #expect(try await store.quotas(at: now).first?.fraction == 0.55)
    }

    /// The app was closed across a reset. The row is not shown and it does not survive the read
    /// that noticed it.
    @Test func forgetsAWindowThatTurnedOverWhileTheAppWasShut() async throws {
        let store = try makeTestStore("quotas-expiry")
        try await store.recordQuotas([
            quota(.claudeCode, "five_hour", 0.94, resets: -60),
            quota(.claudeCode, "seven_day", 0.30),
        ])

        #expect(try await store.quotas(at: now).map(\.window.key) == ["seven_day"])
        // And again, to prove the delete happened rather than the filter running twice.
        #expect(try await store.quotas(at: now.addingTimeInterval(-3600)).map(\.window.key) == ["seven_day"])
    }
}

@Suite("Limit sentence")
struct LimitSentenceTests {
    private func board(_ quotas: [AgentQuota]) -> QuotaBoard { QuotaBoard.make(from: quotas, at: now) }

    private func quota(_ provider: AgentKind, _ key: String, _ fraction: Double?) -> AgentQuota {
        AgentQuota(
            provider: provider,
            window: .named(key),
            measure: fraction.map { .fraction($0) } ?? .unknown,
            resetsAt: now.addingTimeInterval(8100),
            observedAt: now
        )
    }

    @Test func namesTheWindowNearestItsWallAndCountsTheRest() {
        let sentence = MenuBarSummary.limitSentence(
            for: board([
                quota(.claudeCode, "five_hour", 0.42),
                quota(.claudeCode, "seven_day", 0.77),
                quota(.codex, "seven_day", 0.06),
            ]),
            at: now
        )
        #expect(sentence == "Claude Code, week limit 77 percent used, lifts in 2h 15m. 2 other windows")
    }

    @Test func saysSoWhenThereIsNothingToSay() {
        #expect(MenuBarSummary.limitSentence(for: board([]), at: now) == "No limit reported yet")
        #expect(
            MenuBarSummary.limitSentence(for: board([quota(.claudeCode, "five_hour", nil)]), at: now)
                == "Limits reported, none of them measured yet"
        )
    }
}
