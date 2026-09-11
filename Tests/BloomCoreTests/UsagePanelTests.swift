import Testing
import Foundation
@testable import BloomCore

/// A fixed instant, 2026-08-23 15:46:40 UTC, so every countdown here is the same countdown next
/// week. Every clock time below is read on a UTC calendar in an American locale for the same
/// reason.
private let now = Date(timeIntervalSince1970: 1_787_500_000)
private let english = Locale(identifier: "en_US")
private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()
private let fiveHours: TimeInterval = 18_000
private let week: TimeInterval = 604_800

private func quota(
    _ provider: AgentKind = .claudeCode,
    _ window: QuotaWindow,
    _ measure: QuotaMeasure,
    resetsIn: TimeInterval? = nil,
    observedAt: Date = now
) -> AgentQuota {
    AgentQuota(
        provider: provider,
        window: window,
        measure: measure,
        resetsAt: resetsIn.map { now.addingTimeInterval($0) },
        observedAt: observedAt
    )
}

private func session(_ used: Double?, resetsIn: TimeInterval?) -> AgentQuota {
    quota(.claudeCode, .named("five_hour"), used.map { .fraction($0) } ?? .unknown, resetsIn: resetsIn)
}

private func reading(
    _ quota: AgentQuota,
    isSession: Bool = true,
    _ options: UsageDisplayOptions = UsageDisplayOptions(calendar: utc, locale: english)
) -> UsageMeterReading {
    UsageMeterReading.of(quota, isSession: isSession, at: now, options: options)
}

// MARK: - Words and numbers

@Suite("Usage format")
struct UsageFormatTests {
    @Test("durations round minutes up and keep a zero hour after days")
    func compactDuration() {
        #expect(UsageFormat.compactDuration(40) == "1m")
        #expect(UsageFormat.compactDuration(3600) == "1h")
        #expect(UsageFormat.compactDuration(17_820) == "4h 57m")
        #expect(UsageFormat.compactDuration(4 * 86_400) == "4d 0h")
        #expect(UsageFormat.compactDuration(18 * 86_400 + 23 * 3600) == "18d 23h")
    }

    @Test("a countdown turns into soon inside the last five minutes and after the moment")
    func relative() {
        #expect(UsageFormat.relative("Resets", until: now.addingTimeInterval(17_820), from: now) == "Resets in 4h 57m")
        #expect(UsageFormat.relative("Resets", until: now.addingTimeInterval(200), from: now) == "Resets soon")
        #expect(UsageFormat.relative("Resets", until: now.addingTimeInterval(-5), from: now) == "Resets soon")
    }

    @Test("a clock time says today, tomorrow or the date, on the clock asked for")
    func absolute() {
        func at(_ offset: TimeInterval, _ clock: UsageTimeFormat = .twelveHour) -> String {
            UsageFormat.absolute(
                "Resets", at: now.addingTimeInterval(offset), from: now,
                clock: clock, calendar: utc, locale: english
            )
        }
        #expect(at(3600) == "Resets today at 4:46 PM")
        #expect(at(86_400) == "Resets tomorrow at 3:46 PM")
        #expect(at(3 * 86_400) == "Resets Aug 26 at 3:46 PM")
        #expect(at(3600, .twentyFourHour) == "Resets today at 16:46")
    }

    @Test("money is cents in a row, whole in the menu bar, and folded from a thousand up")
    func money() {
        #expect(UsageFormat.money(17.2) == "$17.20")
        #expect(UsageFormat.money(2059) == "$2.1K")
        #expect(UsageFormat.trayMoney(130.4) == "$130")
        #expect(UsageFormat.count(821) == "821")
        #expect(UsageFormat.count(12_900) == "12.9K")
    }

    @Test("the footer counts minutes up and seconds in the last minute")
    func nextUpdate() {
        #expect(UsageFormat.nextUpdate(lastAskedAt: now - 180, interval: 600, at: now) == "Next update in 7m")
        #expect(UsageFormat.nextUpdate(lastAskedAt: now - 555, interval: 600, at: now) == "Next update in 45s")
    }
}

// MARK: - Meters

@Suite("Usage meter reading")
struct UsageMeterReadingTests {
    @Test("a window outlasting its clock is blue and says nothing")
    func healthy() {
        let calm = reading(session(0.3, resetsIn: fiveHours / 2))
        #expect(calm.tone == .normal)
        #expect(calm.headline == "70% left")
        #expect(calm.headlineAlternate == "30% used")
        #expect(calm.status == nil)
        #expect(calm.paceTick == nil)
        #expect(calm.paceTooltip == "~40% left at reset")
        #expect(calm.trailing == "Resets in 2h 30m")
        #expect(calm.menuBarValue == "70%")
    }

    @Test("always show pacing puts the projection and the tick on a calm window")
    func alwaysPacing() {
        let options = UsageDisplayOptions(alwaysShowsPacing: true, calendar: utc, locale: english)
        let calm = reading(session(0.3, resetsIn: fiveHours / 2), options)
        #expect(calm.status?.text == "~40% left at reset")
        #expect(calm.paceTick == 0.5)
    }

    @Test("landing inside the last tenth is yellow with the spare said")
    func cuttingItClose() {
        let close = reading(session(0.47, resetsIn: fiveHours / 2))
        #expect(close.tone == .warning)
        #expect(close.status?.text == "~6% spare")
        #expect(close.status?.tooltip == "~94% used at reset")
        #expect(close.paceTick != nil)
    }

    @Test("running out before the reset is red with the moment it runs out")
    func runningOut() {
        let behind = reading(session(0.6, resetsIn: fiveHours / 2))
        #expect(behind.tone == .critical)
        #expect(behind.status?.text == "Limit in 1h 40m")
        #expect(behind.status?.showsFlame == true)
        #expect(behind.status?.isDeadline == true)
        #expect(behind.paceTooltip == "~20% over limit at reset")
    }

    @Test("a spent window is red and says so, judged at the precision it prints")
    func spent() {
        let gone = reading(session(0.996, resetsIn: 3600))
        #expect(gone.headline == "0% left")
        #expect(gone.tone == .critical)
        #expect(gone.status?.text == UsageMeterReading.limitReached)
    }

    @Test("a barely touched window is not alarmed by its own first minutes")
    func earlyNoise() {
        let early = reading(session(0.04, resetsIn: fiveHours - 200))
        #expect(early.tone == .normal)
        #expect(early.status == nil)
    }

    @Test("money with no clock falls back to the level bands")
    func extraUsage() {
        let extra = reading(
            quota(.claudeCode, QuotaWindow(key: "extra_usage", label: "Extra usage"), .counted(used: 45, limit: 50, unit: "USD")),
            isSession: false
        )
        #expect(extra.tone == .critical)
        #expect(extra.headline == "$5.00 left")
        #expect(extra.trailing == "$50 limit")
        #expect(extra.menuBarValue == "$5")
    }

    @Test("a session with no reset has not started")
    func notStarted() {
        let fresh = reading(session(nil, resetsIn: nil))
        #expect(fresh.trailing == UsageMeterReading.notStarted)
        #expect(fresh.trailingTooltip == UsageMeterReading.notStartedTooltip)
        #expect(fresh.headline == "100% left")
        #expect(fresh.tone == .normal)
    }

    @Test("a window nobody measured is an empty track, not a zero")
    func noData() {
        let unmeasured = reading(quota(.claudeCode, .named("seven_day"), .unknown, resetsIn: week / 2), isSession: false)
        #expect(unmeasured.tone == .empty)
        #expect(unmeasured.headline == UsageMeterReading.emptyHeadline)
        #expect(unmeasured.trailing == UsageMeterReading.noData)
        #expect(unmeasured.menuBarValue == nil)
    }

    @Test("used mode fills with what has gone and mirrors nothing else")
    func usedMode() {
        let options = UsageDisplayOptions(meterStyle: .used, calendar: utc, locale: english)
        let used = reading(session(0.3, resetsIn: fiveHours / 2), options)
        #expect(used.headline == "30% used")
        #expect(used.fill == 0.3)
        #expect(used.menuBarValue == "30%")
    }

    @Test("exact time reads a clock time and offers the countdown as the other form")
    func exactTime() {
        let options = UsageDisplayOptions(resetDisplay: .exactTime, timeFormat: .twelveHour, calendar: utc, locale: english)
        let clock = reading(session(0.3, resetsIn: fiveHours / 2), options)
        #expect(clock.trailing == "Resets today at 6:16 PM")
        #expect(clock.trailingAlternate == "Resets in 2h 30m")
    }
}

// MARK: - Metrics

@Suite("Usage catalogue")
struct UsageCatalogueTests {
    @Test("Claude Code's windows are named as OpenUsage names them, in its order")
    func claudeTitles() {
        let metrics = UsageCatalogue.metrics(quotas: [
            quota(.claudeCode, .named("seven_day_sonnet"), .fraction(0.1), resetsIn: week / 2),
            quota(.claudeCode, QuotaWindow(key: "extra_usage", label: "Extra usage"), .counted(used: 17.2, limit: 50, unit: "USD")),
            quota(.claudeCode, QuotaWindow(key: "seven_day_model_fable", label: "Week (Fable)", duration: week), .fraction(0.7), resetsIn: week / 2),
            quota(.claudeCode, .named("seven_day"), .fraction(0.6), resetsIn: week / 2),
            quota(.claudeCode, .named("five_hour"), .fraction(0.04), resetsIn: 3600),
        ], accounts: [:], at: now)[.claudeCode] ?? []
        #expect(metrics.map(\.title) == ["Session", "Weekly", "Fable", "Extra Usage", "Sonnet"])
        #expect(metrics.first?.isSession == true)
    }

    @Test("a Codex slot is named by its length, so the week keeps its star across plans")
    func codexByLength() {
        let weekly = UsageCatalogue.metric(for: quota(.codex, .lasting(week, key: "primary"), .fraction(0.1), resetsIn: week / 2))
        let short = UsageCatalogue.metric(for: quota(.codex, .lasting(fiveHours, key: "primary"), .fraction(0.1), resetsIn: 3600))
        #expect(weekly.id == UsageMetricID("codex/weekly"))
        #expect(weekly.title == "Weekly")
        #expect(short.id == UsageMetricID("codex/session"))
        #expect(short.title == "Session")
    }

    @Test("an extra Codex limit reads as its own name")
    func spark() throws {
        let quotas = AgentQuotaAdapters.quotas(fromRateLimitEvent: Data(codexRead.utf8), at: now)
        let keys = Set(quotas.map(\.window.key))
        #expect(keys.contains("primary"))
        #expect(keys.contains("codex_bengalfox.primary"))
        #expect(keys.contains("codex_bengalfox.secondary"))
        #expect(!keys.contains("codex.primary"))

        let metrics = quotas.map(UsageCatalogue.metric(for:))
        let titles = Set(metrics.map(\.title))
        #expect(titles.contains("Spark"))
        #expect(titles.contains("Spark Weekly"))
        #expect(titles.contains("Weekly"))
    }

    @Test("an allowance with no ceiling is a figure rather than a meter")
    func uncapped() {
        let metric = UsageCatalogue.metric(
            for: quota(.claudeCode, QuotaWindow(key: "extra_usage", label: "Extra usage"), .counted(used: 4, limit: nil, unit: "USD"))
        )
        guard case .value(let text, let tray, _) = metric.content else {
            Issue.record("expected a value row")
            return
        }
        #expect(text == "$4.00 spent")
        #expect(tray == "$4")
    }

    @Test("balances come from the account, and a turned over window is dropped")
    func balancesAndExpiry() {
        let account = AgentAccount(
            provider: .codex,
            credits: .init(balance: 821),
            resetCredits: .init(available: 1, expiries: [now.addingTimeInterval(86_400)]),
            observedAt: now
        )
        let metrics = UsageCatalogue.metrics(
            quotas: [quota(.codex, .lasting(week, key: "primary"), .fraction(0.5), resetsIn: -1)],
            accounts: [.codex: account],
            at: now
        )[.codex] ?? []
        #expect(metrics.map(\.title) == ["Credits", "Rate Limit Resets"])
        guard case .value(let credits, _, _) = metrics[0].content else {
            Issue.record("expected a value row")
            return
        }
        #expect(credits == "821 credits")
    }
}

// MARK: - Accounts

@Suite("Agent accounts")
struct AgentAccountTests {
    @Test("Claude Code's plan comes out of get_usage")
    func claudePlan() {
        let answer = """
        {"session":{"total_cost_usd":0},"subscription_type":"max","rate_limits_available":true,"rate_limits":{}}
        """
        let account = AgentAccountReader.account(from: Data(answer.utf8), at: now)
        #expect(account?.provider == .claudeCode)
        #expect(account?.plan == "Max")
    }

    @Test("Codex's plan, credits and resets come out of the read answer")
    func codex() throws {
        let account = try #require(AgentAccountReader.account(from: Data(codexRead.utf8), at: now))
        #expect(account.provider == .codex)
        #expect(account.plan == "Pro 5x")
        #expect(account.credits?.balance == 0)
        #expect(account.resetCredits?.available == 1)
        #expect(account.resetCredits?.expiries == [Date(timeIntervalSince1970: 1_789_949_965)])
    }

    @Test("Codex's plan tokens read the way OpenAI names them")
    func codexPlans() {
        #expect(AgentAccountReader.codexPlan("pro") == "Pro 20x")
        #expect(AgentAccountReader.codexPlan("self_serve_business_prolite") == "Business Premium")
        #expect(AgentAccountReader.codexPlan("team") == "Team")
        #expect(AgentAccountReader.codexPlan("") == nil)
    }
}

// MARK: - Layout

@Suite("Usage layout")
struct UsageLayoutTests {
    private let claude = UsageCatalogue.metrics(quotas: [
        quota(.claudeCode, .named("five_hour"), .fraction(0.3), resetsIn: fiveHours / 2),
        quota(.claudeCode, .named("seven_day"), .fraction(0.6), resetsIn: week / 2),
        quota(.claudeCode, .named("seven_day_sonnet"), .fraction(0.1), resetsIn: week / 2),
        quota(.claudeCode, QuotaWindow(key: "extra_usage", label: "Extra usage"), .counted(used: 17.2, limit: 50, unit: "USD")),
    ], accounts: [:], at: now)

    @Test("a metric seen for the first time gets its default star, once")
    func adoption() {
        var layout = UsageLayout()
        let first = layout.adopt(claude)
        let second = layout.adopt(claude)
        #expect(first)
        #expect(!second)
        #expect(layout.pins == [UsageMetricID("claudeCode/five_hour"), UsageMetricID("claudeCode/seven_day")])

        var unstarred = layout
        let session = claude[.claudeCode]![0]
        let outcome = unstarred.togglePin(session)
        #expect(outcome == .unpinned)
        let again = unstarred.adopt(claude)
        #expect(!again)
        #expect(!unstarred.isPinned(session.id))
    }

    @Test("a provider gets two stars and no more")
    func pinCap() {
        var layout = UsageLayout()
        layout.adopt(claude)
        let extra = claude[.claudeCode]!.first { $0.title == "Extra Usage" }!
        let outcome = layout.togglePin(extra)
        #expect(outcome == .denied)
        #expect(!layout.isPinned(extra.id))
    }

    @Test("one model's week waits behind the caret, and a hidden row is gone")
    func sections() throws {
        var layout = UsageLayout()
        layout.setHidden(true, for: UsageMetricID("claudeCode/extra_usage"))
        let section = try #require(layout.sections(for: claude).first)
        #expect(section.alwaysVisible.map(\.title) == ["Session", "Weekly"])
        #expect(section.onDemand.map(\.title) == ["Sonnet"])
        #expect(!section.isExpanded)
    }

    @Test("a card whose every row is on demand shows them anyway")
    func promotion() throws {
        var layout = UsageLayout()
        for metric in claude[.claudeCode]! { layout.setPlacement(.onDemand, for: metric.id) }
        let section = try #require(layout.sections(for: claude).first)
        #expect(section.alwaysVisible.count == 4)
        #expect(section.onDemand.isEmpty)
    }

    @Test("a dragged row lands where it was dropped, in the section it was dropped in")
    func move() throws {
        var layout = UsageLayout()
        let all = claude[.claudeCode]!
        layout.move(UsageMetricID("claudeCode/seven_day_sonnet"), before: UsageMetricID("claudeCode/five_hour"), into: .alwaysVisible, among: all)
        let section = try #require(layout.sections(for: claude).first)
        #expect(section.alwaysVisible.map(\.title) == ["Sonnet", "Session", "Weekly", "Extra Usage"])
        #expect(section.onDemand.isEmpty)
    }

    @Test("a switched off provider draws no card and no strip, and a reset turns it back on")
    func disabledAndReset() {
        var layout = UsageLayout()
        layout.adopt(claude)
        layout.setEnabled(false, for: .claudeCode)
        #expect(layout.sections(for: claude).isEmpty)
        #expect(layout.pinnedMetrics(in: claude).isEmpty)

        layout.reset(.claudeCode)
        #expect(layout.isEnabled(.claudeCode))
        #expect(layout.pins.isEmpty)
        #expect(layout.adopted.isEmpty)
    }

    @Test("a layout survives the round trip, and a partial one keeps what it carries")
    func storage() throws {
        var layout = UsageLayout()
        layout.adopt(claude)
        layout.setHidden(true, for: UsageMetricID("claudeCode/extra_usage"))
        layout.toggleExpanded(.claudeCode)
        let data = try JSONEncoder().encode(layout)
        #expect(try JSONDecoder().decode(UsageLayout.self, from: data) == layout)

        let partial = try JSONDecoder().decode(UsageLayout.self, from: Data(#"{"pins":["claudeCode/five_hour"]}"#.utf8))
        #expect(partial.pins == [UsageMetricID("claudeCode/five_hour")])
        #expect(partial.providerOrder == UsageLayout.defaultProviderOrder)
    }
}

// MARK: - The strip

@Suite("Menu bar usage strip")
struct MenuBarUsageStripTests {
    @Test("each provider's starred figures, top first, and the first four as bars")
    func figures() {
        let metrics = UsageCatalogue.metrics(quotas: [
            quota(.claudeCode, .named("five_hour"), .fraction(0.3), resetsIn: fiveHours / 2),
            quota(.claudeCode, .named("seven_day"), .fraction(0.6), resetsIn: week / 2),
            quota(.codex, .lasting(week, key: "primary"), .fraction(0.1), resetsIn: week / 2),
        ], accounts: [:], at: now)
        var layout = UsageLayout()
        layout.adopt(metrics)
        let strip = MenuBarUsageStrip.make(layout: layout, metrics: metrics, at: now)
        #expect(strip.groups.map(\.provider) == [.claudeCode, .codex])
        #expect(strip.groups.map(\.values) == [["70%", "40%"], ["90%"]])
        #expect(strip.bars == [0.7, 0.4, 0.9])
        #expect(strip.spoken.contains("Claude Code Session 70% left"))
    }

    @Test("a star with no figure is left out rather than drawn as a placeholder")
    func noPlaceholders() {
        let metrics = UsageCatalogue.metrics(quotas: [
            quota(.claudeCode, .named("five_hour"), .unknown, resetsIn: 3600),
            quota(.claudeCode, .named("seven_day"), .unknown, resetsIn: week / 2),
        ], accounts: [:], at: now)
        var layout = UsageLayout()
        layout.adopt(metrics)
        #expect(MenuBarUsageStrip.make(layout: layout, metrics: metrics, at: now).isEmpty)
    }
}

// MARK: - Marks

@Suite("SVG path")
struct SVGPathTests {
    @Test("absolute commands, including the horizontal and vertical shorthands")
    func absolute() {
        let path = SVGPath("M0 0L10 0V10H0Z")
        #expect(path.commands == [
            .move(CGPoint(x: 0, y: 0)), .line(CGPoint(x: 10, y: 0)), .line(CGPoint(x: 10, y: 10)),
            .line(CGPoint(x: 0, y: 10)), .close,
        ])
        #expect(path.bounds == CGRect(x: 0, y: 0, width: 10, height: 10))
    }

    @Test("relative commands, implicit repeats and numbers run together")
    func relative() {
        #expect(SVGPath("m1 1l2 0 0 2z").commands == [
            .move(CGPoint(x: 1, y: 1)), .line(CGPoint(x: 3, y: 1)), .line(CGPoint(x: 3, y: 3)), .close,
        ])
        #expect(SVGPath("M-1.5.5").commands == [.move(CGPoint(x: -1.5, y: 0.5))])
    }

    @Test("both provider marks parse whole, inside their hundred point square")
    func marks() throws {
        for provider in [AgentKind.claudeCode, .codex] {
            let mark = try #require(ProviderMark.path(for: provider))
            #expect(mark.commands.count > 50)
            #expect(mark.bounds.minX >= 0 && mark.bounds.maxX <= 100)
            #expect(mark.bounds.width > 50)
        }
        #expect(ProviderMark.path(for: .cursor) == nil)
    }
}

// MARK: - Keep Awake

@Suite("Keep awake")
struct KeepAwakeTests {
    @Test("a timed session runs out at its moment and an open one does not")
    func sessions() {
        let timed = KeepAwakeSession.lasting(3600, from: now)
        #expect(timed.isActive(at: now.addingTimeInterval(100)))
        #expect(!timed.isActive(at: now.addingTimeInterval(3600)))
        #expect(KeepAwakeSession.indefinitely(from: now).isActive(at: now.addingTimeInterval(1_000_000)))
    }

    @Test("either a session or a running agent with the switch on holds the Mac awake")
    func holds() {
        let timed = KeepAwakeSession.lasting(3600, from: now)
        #expect(KeepAwake.holdsAwake(session: timed, whileAgentsRun: false, runningCount: 0, at: now))
        #expect(KeepAwake.holdsAwake(session: nil, whileAgentsRun: true, runningCount: 1, at: now))
        #expect(!KeepAwake.holdsAwake(session: nil, whileAgentsRun: true, runningCount: 0, at: now))
        #expect(!KeepAwake.holdsAwake(session: nil, whileAgentsRun: false, runningCount: 3, at: now))
    }

    @Test("the card says whether it is on, and why or for how long")
    func status() {
        func status(_ session: KeepAwakeSession?, _ whileRunning: Bool = true, running: Int = 0) -> KeepAwake.Status {
            KeepAwake.status(
                session: session, whileAgentsRun: whileRunning, runningCount: running, at: now,
                clock: .twelveHour, calendar: utc, locale: english
            )
        }
        #expect(status(.indefinitely(from: now)).detail == "Until you stop it")
        #expect(status(.lasting(3600, from: now)).detail == "1h left, until 4:46 PM")
        #expect(status(.lasting(3600, from: now)).isOn)
        #expect(status(nil, running: 2).detail == "While 2 agents run")
        #expect(status(nil, running: 1).detail == "While 1 agent runs")
        #expect(!status(nil).isOn)
        #expect(status(nil).detail == "Stays awake while agents run")
        #expect(status(nil, false).detail == "Nothing is keeping this Mac awake")
    }

    @Test("a time of day picked without a date is its next occurrence")
    func nextOccurrence() throws {
        let later = try #require(utc.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: 17, minute: 30)))
        let earlier = try #require(utc.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: 9, minute: 0)))
        #expect(KeepAwake.nextOccurrence(of: later, after: now, calendar: utc)
            == utc.date(from: DateComponents(year: 2026, month: 8, day: 23, hour: 17, minute: 30)))
        #expect(KeepAwake.nextOccurrence(of: earlier, after: now, calendar: utc)
            == utc.date(from: DateComponents(year: 2026, month: 8, day: 24, hour: 9, minute: 0)))
    }

    @Test("a session is saved, read back, and forgotten once it has run out")
    func storage() throws {
        let defaults = try #require(UserDefaults(suiteName: "bloom.keepawake.\(UUID().uuidString)"))
        let session = KeepAwakeSession.lasting(3600, from: now)
        KeepAwake.save(session, to: defaults)
        #expect(KeepAwake.load(from: defaults, at: now) == session)
        #expect(KeepAwake.load(from: defaults, at: now.addingTimeInterval(7200)) == nil)
        KeepAwake.save(nil, to: defaults)
        #expect(defaults.data(forKey: KeepAwake.sessionKey) == nil)
    }
}

/// `Tests/fixtures/codex-rate-limits-read.json`, the answer codex-cli 0.147.0 gave to
/// `account/rateLimits/read`, inline so the three suites above can read it without a bundle.
private let codexRead = """
{"id":2,"result":{"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":1787986128},"secondary":null,"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},"individualLimit":null,"spendControlReached":false,"planType":"prolite","rateLimitReachedType":null},"rateLimitsByLimitId":{"codex_bengalfox":{"limitId":"codex_bengalfox","limitName":"GPT-5.3-Codex-Spark","primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":1787541121},"secondary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":1788127921},"credits":null,"individualLimit":null,"spendControlReached":null,"planType":"prolite","rateLimitReachedType":null},"codex":{"limitId":"codex","limitName":null,"primary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":1787986128},"secondary":null,"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},"individualLimit":null,"spendControlReached":false,"planType":"prolite","rateLimitReachedType":null}},"rateLimitResetCredits":{"availableCount":1,"credits":[{"id":"RateLimitResetCredit_REDACTED","resetType":"codexRateLimits","status":"available","grantedAt":1787357965,"expiresAt":1789949965,"title":"Full reset","description":"Thanks for using Codex! You've been granted one free rate limit reset."}]}}}
"""
