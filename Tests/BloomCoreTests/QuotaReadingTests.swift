import Testing
import Foundation
@testable import BloomCore

/// The reference clock. Fixed, because every assertion here is about a window measured against an
/// instant, and `Date()` would make half of them true only in the hour they were written in.
private let now = Date(timeIntervalSince1970: 1_787_500_000)

/// A pound and a dollar behave differently and neither of them is "whatever machine ran the tests".
private let english = Locale(identifier: "en_GB")
private let american = Locale(identifier: "en_US")

private let week: TimeInterval = 604_800

private func quota(
    _ provider: AgentKind = .claudeCode,
    _ window: QuotaWindow = .named("seven_day"),
    used: Double?,
    resets: TimeInterval?
) -> AgentQuota {
    AgentQuota(
        provider: provider,
        window: window,
        measure: used.map { .fraction($0) } ?? .unknown,
        resetsAt: resets.map { now.addingTimeInterval($0) },
        observedAt: now
    )
}

@Suite("Quota severity ramp")
struct QuotaSeverityRampTests {
    /// The owner's two numbers, asked for after looking at his own account in the panel.
    @Test func stepsAtEightyAndNinety() {
        #expect(QuotaSeverity.warningAt == 0.8)
        #expect(QuotaSeverity.criticalAt == 0.9)
        #expect(QuotaSeverity.of(0.79) == .calm)
        #expect(QuotaSeverity.of(0.85) == .warning)
        #expect(QuotaSeverity.of(0.95) == .critical)
        #expect(QuotaSeverity.of(1.0) == .spent)
        #expect(QuotaSeverity.of(1.03) == .spent)
    }

    /// Both boundaries are inclusive, and it has to be settled rather than left to whichever
    /// comparison somebody typed: `QuotaPhrase.figure` rounds down, so the first fraction that
    /// prints as "80%" is exactly 0.8, and that figure has to be the first orange one.
    @Test func takesTheBoundaryItselfAsTheNewStep() {
        #expect(QuotaSeverity.of(0.8) == .warning)
        #expect(QuotaSeverity.of(0.9) == .critical)
        #expect(QuotaPhrase.figure(for: quota(used: 0.8, resets: 3600)) == "80%")
        #expect(QuotaPhrase.figure(for: quota(used: 0.9, resets: 3600)) == "90%")
    }
}

@Suite("Quota pace")
struct QuotaPaceTests {
    /// Halfway through a week with 60 percent gone: ten points ahead of the clock.
    @Test func measuresHowFarAheadOfItsOwnClockAWindowIs() throws {
        let pace = try #require(QuotaPace.of(
            quota(.claudeCode, .named("seven_day"), used: 0.6, resets: week / 2), at: now
        ))
        #expect(abs(pace.elapsed - 0.5) < 0.0001)
        #expect(abs(pace.overspend - 0.1) < 0.0001)
    }

    /// An allowance outlasting its own clock is not ahead of anything, and the answer is zero
    /// rather than a negative number nothing would know what to do with.
    @Test func isNotAheadWhenTheAllowanceIsOutlastingTheClock() throws {
        let pace = try #require(QuotaPace.of(
            quota(.claudeCode, .named("seven_day"), used: 0.2, resets: week / 2), at: now
        ))
        #expect(pace.overspend == 0)
        #expect(pace.runsOutIn == nil)
    }

    /// **The sentence the whole thing exists for.** 71 percent gone with three and a quarter days
    /// of the week behind it, which is the owner's own Fable weekly as measured. At that rate the
    /// remaining 29 percent lasts about another day and a third, which is well inside the week.
    @Test func forecastsRunningOutBeforeTheWindowLifts() throws {
        let elapsed = week * 0.4643
        let pace = try #require(QuotaPace.of(
            quota(.claudeCode, .named("seven_day"), used: 0.71, resets: week - elapsed), at: now
        ))
        let seconds = try #require(pace.runsOutIn)
        #expect(seconds > 100_000 && seconds < 130_000)
        #expect(QuotaCountdown.phrase(after: seconds) == "in 1d 7h")
        // And said the way a forecast has to be said, which is not the way a reset time is.
        #expect(QuotaCountdown.rough(after: seconds) == "in about a day")
    }

    /// The ordinary case, and the one that must produce no sentence at all: a window that will
    /// comfortably see out its own week.
    @Test func saysNothingWhenTheAllowanceWillSeeTheWindowOut() {
        let pace = QuotaPace.of(
            quota(.claudeCode, .named("seven_day"), used: 0.5, resets: week * 0.2), at: now
        )
        #expect(pace?.runsOutIn == nil)
    }

    /// Barely ahead is not ahead. Sixty percent gone with fifty seven percent of the week behind
    /// it forecasts running out two and a half days into a window that lifts in three, which is
    /// true, is three points of overspend, and would put a sentence on the row almost every day.
    @Test func willNotForecastAShortfallItOnlyJustReaches() throws {
        let pace = try #require(QuotaPace.of(
            quota(.claudeCode, .named("seven_day"), used: 0.6, resets: 260_000), at: now
        ))
        #expect(pace.overspend > 0)
        #expect(pace.runsOutIn == nil)
    }

    /// Two heavy turns in the first ten minutes of a week is a rate that projects catastrophe by
    /// Tuesday and is pure noise.
    @Test func willNotForecastFromTheFirstMomentsOfAWindow() {
        let pace = QuotaPace.of(
            quota(.claudeCode, .named("seven_day"), used: 0.3, resets: week * 0.95), at: now
        )
        #expect(pace?.runsOutIn == nil)
    }

    /// A window already spent has nothing left to forecast, and one nothing has been taken from
    /// has a rate of zero, which never reaches anything.
    @Test func forecastsNothingForASpentWindowOrAnUntouchedOne() {
        let spent = QuotaPace.of(
            quota(.claudeCode, .named("seven_day"), used: 1, resets: week / 2), at: now
        )
        let untouched = QuotaPace.of(
            quota(.claudeCode, .named("seven_day"), used: 0, resets: week / 2), at: now
        )
        #expect(spent?.runsOutIn == nil)
        #expect(untouched?.runsOutIn == nil)
    }

    /// Three things are needed and every one of them genuinely goes missing: a measured fullness,
    /// a reset time, and a stated length. Nothing is inferred in their absence.
    @Test func declinesAWindowThatCannotBePaced() {
        #expect(QuotaPace.of(quota(used: nil, resets: 3600), at: now) == nil)
        #expect(QuotaPace.of(quota(used: 0.5, resets: nil), at: now) == nil)
        #expect(QuotaPace.of(
            quota(.claudeCode, QuotaWindow(key: "extra_usage", label: "Extra usage"),
                  used: 0.5, resets: 3600),
            at: now
        ) == nil)
    }
}

@Suite("Quota phrasing")
struct QuotaPhraseTests {
    /// One voice. The panel used to say "Lifts in 3d" on one row and "in 3h 13m" two rows under
    /// it, which is one idea in two voices, and neither was reachable from a test.
    @Test func saysWhenEveryWindowLiftsInTheSameWords() {
        let weekly = quota(.claudeCode, .named("seven_day"), used: 0.6, resets: 260_000)
        let session = quota(.claudeCode, .named("five_hour"), used: 0.04, resets: 11_580)
        #expect(QuotaPhrase.footnote(for: weekly, at: now, locale: english) == "Lifts in 3d")
        #expect(QuotaPhrase.footnote(for: session, at: now, locale: english) == "Lifts in 3h 13m")
    }

    /// Rounded down, never up. Rounding 0.999 to "100%" says a window is spent while there is
    /// still room in it.
    @Test func roundsAFigureDown() {
        #expect(QuotaPhrase.figure(for: quota(used: 0.999, resets: 3600)) == "99%")
        #expect(QuotaPhrase.figure(for: quota(used: 0, resets: 3600)) == "0%")
        #expect(QuotaPhrase.figure(for: quota(used: 1.03, resets: 3600)) == "100%")
    }

    /// A measured zero and an unmeasured window are different facts and must read differently. A
    /// zero is a measurement; this is the absence of one.
    @Test func willNotPrintAZeroForAWindowNobodyMeasured() {
        #expect(QuotaPhrase.figure(for: quota(used: nil, resets: 3600)) == "not reported")
    }

    /// The forecast, on the row it is true of, in the same voice as the countdown beside it.
    @Test func addsTheForecastOnlyWhereItIsTrue() {
        let elapsed = week * 0.4643
        let pressed = quota(.claudeCode, .named("seven_day"), used: 0.71, resets: week - elapsed)
        let calm = quota(.claudeCode, .named("seven_day"), used: 0.2, resets: week - elapsed)
        #expect(QuotaPhrase.footnote(for: pressed, at: now, forecasting: true, locale: english)
            == "Lifts in 3d. At this rate it runs out in about a day")
        #expect(QuotaPhrase.footnote(for: calm, at: now, forecasting: true, locale: english)
            == "Lifts in 3d")
        // And nothing at all on a row the panel did not pick, however true the arithmetic is.
        #expect(QuotaPhrase.footnote(for: pressed, at: now, locale: english) == "Lifts in 3d")
    }

    /// Money, for the one row that is money rather than a window. "$17.20 of $50.00" is a thing
    /// somebody can act on and "34 percent" of an unnamed sum is not.
    @Test func saysMoneyAsMoney() {
        let extra = AgentQuota(
            provider: .claudeCode,
            window: QuotaWindow(key: "extra_usage", label: "Extra usage"),
            measure: .counted(used: 17.2, limit: 50, unit: "USD"),
            resetsAt: nil,
            observedAt: now
        )
        #expect(QuotaPhrase.footnote(for: extra, at: now, locale: american) == "$17.20 of $50.00")
        // A reader outside the currency's own country gets it disambiguated, which is the
        // formatter doing its job and is why the locale is a parameter rather than a literal.
        #expect(QuotaPhrase.footnote(for: extra, at: now, locale: english) == "US$17.20 of US$50.00")
    }

    /// A metered account with no stated ceiling is a thing to show rather than an error.
    @Test func saysAnAmountWithNoCeilingAsAnAmount() {
        let extra = AgentQuota(
            provider: .claudeCode,
            window: QuotaWindow(key: "extra_usage", label: "Extra usage"),
            measure: .counted(used: 4, limit: nil, unit: "USD"),
            resetsAt: nil,
            observedAt: now
        )
        #expect(QuotaPhrase.footnote(for: extra, at: now, locale: american) == "$4.00 so far")
    }
}

@Suite("Quota lines")
struct QuotaLineTests {
    private func board(_ quotas: [AgentQuota]) -> QuotaBoard { QuotaBoard.make(from: quotas, at: now) }

    /// **The order the owner asked for**: each provider in turn, and inside a provider the
    /// shortest window first, so the five hour window sits above the week.
    @Test func drawsEachProviderInTurnShortestWindowFirst() {
        let lines = board([
            quota(.codex, .lasting(week, key: "primary"), used: 0, resets: week / 2),
            quota(.claudeCode, .named("seven_day"), used: 0.6, resets: week / 2),
            quota(.claudeCode, .named("five_hour"), used: 0.04, resets: 3600),
        ]).lines(at: now, locale: english)

        #expect(lines.map(\.title) == [
            "Claude Code · 5 hours", "Claude Code · Week", "Codex · Week",
        ])
    }

    /// The rest of the sort, decided rather than left to land where it falls. A window whose
    /// length nobody stated has nothing to be sorted by and is the least likely to stop the next
    /// turn, so it goes last inside its provider. Extra usage is exactly that window.
    @Test func putsAWindowOfUnstatedLengthLastWithinItsProvider() {
        let lines = board([
            AgentQuota(
                provider: .claudeCode,
                window: QuotaWindow(key: "extra_usage", label: "Extra usage"),
                measure: .counted(used: 17.2, limit: 50, unit: "USD"),
                resetsAt: nil,
                observedAt: now
            ),
            quota(.claudeCode, .named("seven_day"), used: 0.6, resets: week / 2),
            quota(.claudeCode, .named("five_hour"), used: 0.04, resets: 3600),
        ]).lines(at: now, locale: english)

        #expect(lines.map(\.windowKey) == ["five_hour", "seven_day", "extra_usage"])
    }

    /// Two weekly windows of the same length are one plain week and one counting a single model.
    /// They sort by key, which keeps the plain one above its own breakdown and keeps the order
    /// stable between polls rather than depending on the order a payload happened to list them in.
    @Test func keepsTwoWeekliesInAStableOrder() {
        let scoped = AgentQuota(
            provider: .claudeCode,
            window: QuotaWindow(key: "seven_day_model_fable", label: "Week (Fable)", duration: week),
            measure: .fraction(0.71),
            resetsAt: now.addingTimeInterval(week / 2),
            observedAt: now
        )
        let lines = board([
            scoped,
            quota(.claudeCode, .named("seven_day"), used: 0.6, resets: week / 2),
        ]).lines(at: now, locale: english)

        #expect(lines.map(\.title) == ["Claude Code · Week", "Claude Code · Week (Fable)"])
    }

    /// **Unmeasured is not quiet.** `QuotaSeverity.of(nil)` answers calm, which is right for an
    /// empty board and wrong for a row: it would put a window nobody has measured in the same
    /// bucket as one measured at four percent and let the view paint it as though somebody had
    /// checked. A row with no severity draws no lane.
    @Test func givesAnUnmeasuredWindowNoPlaceOnTheRamp() throws {
        let lines = board([
            quota(.claudeCode, .named("five_hour"), used: nil, resets: 3600),
            quota(.claudeCode, .named("seven_day"), used: 0, resets: week / 2),
        ]).lines(at: now, locale: english)

        #expect(lines[0].severity == nil)
        #expect(lines[0].fill == nil)
        #expect(lines[0].figure == "not reported")
        // And a measured zero is a different row: it has a lane, an empty one, and a figure.
        #expect(lines[1].severity == .calm)
        #expect(lines[1].fill == 0)
        #expect(lines[1].figure == "0%")
    }

    /// A provider that is not installed, not signed in or simply never asked contributes no rows
    /// rather than a row explaining its own absence.
    @Test func drawsNothingAtAllForAnAbsentProvider() {
        let lines = board([
            quota(.claudeCode, .named("five_hour"), used: 0.5, resets: 3600),
        ]).lines(at: now, locale: english)

        #expect(lines.count == 1)
        #expect(lines.allSatisfy { $0.provider == .claudeCode })
    }

    /// The one window a single sentence has to name, which is not the one the panel puts first.
    /// Severity leads, so a wall somebody is hitting now outranks any arithmetic.
    @Test func namesTheNearestWallSeparatelyFromTheOrderItDrawsIn() {
        let made = board([
            quota(.claudeCode, .named("five_hour"), used: 0.04, resets: 3600),
            quota(.claudeCode, .named("seven_day"), used: 0.93, resets: week / 2),
        ])
        #expect(made.lines(at: now, locale: english).first?.windowKey == "five_hour")
        #expect(made.headline?.window.key == "seven_day")
        #expect(made.severity == .critical)
    }

    /// **One forecast per panel.** Two rows out of four carried one on the owner's own board, and
    /// a sentence repeated down a column is a paragraph nobody reads in a menu. The row that gets
    /// it is the one furthest ahead of its own clock.
    @Test func letsOnlyTheWorstRowSayWhatItsRateMeans() {
        let elapsed = week * 0.45
        let made = board([
            AgentQuota(
                provider: .claudeCode,
                window: QuotaWindow(key: "seven_day_model_fable", label: "Week (Fable)", duration: week),
                measure: .fraction(0.71),
                resetsAt: now.addingTimeInterval(week - elapsed),
                observedAt: now
            ),
            quota(.claudeCode, .named("seven_day"), used: 0.62, resets: week - elapsed),
        ])
        let lines = made.lines(at: now, locale: english)

        #expect(made.forecastable(at: now)?.window.key == "seven_day_model_fable")
        #expect(lines.filter { $0.footnote.contains("this rate") }.count == 1)
        #expect(lines.first { $0.windowKey == "seven_day_model_fable" }?
            .footnote.contains("At this rate") == true)
    }

    /// **The case fullness alone cannot read.** Both of these are at 95 percent and both are red.
    /// The weekly has most of a week to run and will not last it; the session lifts in twenty
    /// minutes. The one that gets the top of a one sentence summary is the weekly.
    @Test func tellsTheSameTwoPercentagesApartByTheirClocks() {
        let made = board([
            quota(.claudeCode, .named("five_hour"), used: 0.95, resets: 1200),
            quota(.claudeCode, .named("seven_day"), used: 0.95, resets: week * 0.85),
        ])
        #expect(made.headline?.window.key == "seven_day")
        // The colour still follows utilisation alone, which is the rule as asked for.
        let lines = made.lines(at: now, locale: english)
        #expect(lines.map(\.severity) == [.critical, .critical])
    }
}
