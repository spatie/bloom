import Foundation

/// Whether a window is outlasting its own clock, ported from OpenUsage's `Pace`.
///
/// **A verdict on the rate, not on the level, and that is the difference from `QuotaSeverity`.**
/// Eighty percent of a week gone by Saturday afternoon is fine and eighty percent gone by Monday
/// is not, and the level alone paints both the same. So the projection is the share used divided
/// by the share of the window elapsed, and the meter's colour follows where that lands: inside
/// ninety percent of the limit is healthy, inside the limit is cutting it close, past it runs out
/// before the reset.
///
/// Linear, and a straight line through somebody's working habits is a real assumption. It is why
/// every sentence built on it says "~" and "at reset", and why nothing is projected until the
/// window is at least a minute or one percent in: two turns in the first ten minutes of a week
/// forecast catastrophe by Tuesday and mean nothing.
public enum UsagePace {
    public enum Status: Sendable, Hashable {
        /// At least a tenth of the limit projected to spare.
        case ahead
        /// Lands inside the last tenth.
        case onTrack
        /// Runs past the limit before the reset, or already has.
        case behind
    }

    public struct Result: Sendable, Hashable {
        public var status: Status
        /// Usage at the moment of reset, in the same units as `limit`, at the rate so far.
        public var projectedUsage: Double
    }

    public static func minimumElapsed(period: TimeInterval) -> TimeInterval {
        max(60, period * 0.01)
    }

    public static func evaluate(
        used: Double,
        limit: Double,
        resetsAt: Date,
        period: TimeInterval,
        now: Date
    ) -> Result? {
        guard limit > 0, period > 0, used > 0 else { return nil }
        let elapsed = now.timeIntervalSince(resetsAt.addingTimeInterval(-period))
        guard elapsed >= minimumElapsed(period: period), now < resetsAt else { return nil }

        let projected = used / elapsed * period
        if used >= limit { return Result(status: .behind, projectedUsage: projected) }
        if projected <= limit * 0.9 { return Result(status: .ahead, projectedUsage: projected) }
        if projected <= limit { return Result(status: .onTrack, projectedUsage: projected) }
        return Result(status: .behind, projectedUsage: projected)
    }

    /// Seconds until the limit is reached at the rate so far, when that lands before the reset.
    public static func secondsToRunOut(
        used: Double,
        limit: Double,
        resetsAt: Date,
        period: TimeInterval,
        now: Date
    ) -> TimeInterval? {
        guard let result = evaluate(used: used, limit: limit, resetsAt: resetsAt, period: period, now: now),
              result.status == .behind
        else { return nil }
        let rate = result.projectedUsage / period
        guard rate > 0 else { return nil }
        let eta = (limit - used) / rate
        guard eta > 0, eta < resetsAt.timeIntervalSince(now) else { return nil }
        return eta
    }
}

/// Everything one meter row draws, decided here so the view holds ink and geometry and nothing
/// else. OpenUsage's `WidgetData` meter state, ported rule for rule.
public struct UsageMeterReading: Sendable, Hashable {
    public enum Tone: Sendable, Hashable {
        /// Blue. There is no green: a meter that is fine is the ordinary case and says nothing.
        case normal
        case warning
        case critical
        /// No figure yet: an empty grey track and no fill at all.
        case empty
    }

    /// The warning slot at the trailing end of the title line.
    public struct Status: Sendable, Hashable {
        public var text: String?
        public var showsFlame: Bool
        public var tooltip: String?
        /// Whether the text is a deadline, which a click flips between countdown and clock time.
        public var isDeadline: Bool
    }

    /// How much of the bar is filled, 0 to 1, in the reading the setting asks for: remaining in
    /// Left mode, used in Used mode.
    public var fill: Double
    public var tone: Tone
    /// "99% left", or `emptyHeadline` (a single long dash, as OpenUsage draws it) for a window with
    /// no figure.
    public var headline: String
    /// The same figure read the other way, for the headline's tooltip: "1% used".
    public var headlineAlternate: String?
    /// "Resets in 4h 57m", "Resets today at 5:30 PM", "Not started", "$50 limit", "No data".
    public var trailing: String
    /// The same deadline in the other form, or nothing when the trailing text is not a deadline.
    public var trailingAlternate: String?
    public var trailingTooltip: String?
    public var status: Status?
    /// Where the bar would be if usage were perfectly even across the window, 0 to 1, in the same
    /// reading as `fill`. Nothing when the tick is not drawn.
    public var paceTick: Double?
    /// The projection in words, for the bar's own tooltip.
    public var paceTooltip: String?
    /// The figure the menu bar prints: "64%", "$130". Nothing when there is no figure to print.
    public var menuBarValue: String?

    public static let emptyHeadline = "\u{2014}"
    public static let noData = "No data"
    public static let notStarted = "Not started"
    public static let notStartedTooltip = "Sessions start after you send your first message."
    public static let limitReached = "Limit reached"

    public static func of(
        _ quota: AgentQuota,
        isSession: Bool,
        at now: Date,
        options: UsageDisplayOptions = UsageDisplayOptions()
    ) -> UsageMeterReading {
        let money = moneyUnit(quota)
        let figures = figures(quota)

        // A session window with no reset has not started: the first message is what starts the
        // five hour clock. It reads as a full, calm allowance rather than as missing data.
        if isSession, quota.resetsAt == nil, (figures?.used ?? 0) == 0 {
            let limit = figures?.limit ?? 100
            return UsageMeterReading(
                fill: options.meterStyle == .left ? 1 : 0,
                tone: .normal,
                headline: headline(used: 0, limit: limit, money: money, style: options.meterStyle),
                headlineAlternate: headline(used: 0, limit: limit, money: money, style: options.meterStyle.toggled),
                trailing: notStarted,
                trailingTooltip: notStartedTooltip,
                menuBarValue: trayValue(used: 0, limit: limit, money: money, style: options.meterStyle)
            )
        }

        guard let (used, limit) = figures, limit > 0 else {
            return UsageMeterReading(
                fill: 0,
                tone: .empty,
                headline: emptyHeadline,
                trailing: noData
            )
        }

        let shareUsed = min(max(used / limit, 0), 1)
        var reading = UsageMeterReading(
            fill: options.meterStyle == .left ? 1 - shareUsed : shareUsed,
            tone: .normal,
            headline: headline(used: used, limit: limit, money: money, style: options.meterStyle),
            headlineAlternate: headline(used: used, limit: limit, money: money, style: options.meterStyle.toggled),
            trailing: "",
            menuBarValue: trayValue(used: used, limit: limit, money: money, style: options.meterStyle)
        )

        if let resetsAt = quota.resetsAt {
            reading.trailing = UsageFormat.deadline(
                "Resets", at: resetsAt, from: now, display: options.resetDisplay,
                clock: options.timeFormat, calendar: options.calendar, locale: options.locale
            )
            reading.trailingAlternate = UsageFormat.deadline(
                "Resets", at: resetsAt, from: now, display: options.resetDisplay.toggled,
                clock: options.timeFormat, calendar: options.calendar, locale: options.locale
            )
        } else if let money {
            reading.trailing = "\(UsageFormat.trayMoney(limit, code: money)) limit"
        }

        // Spent is judged at the precision the headline prints, so "0% left" is never drawn blue.
        if isSpent(used: used, limit: limit, money: money != nil) {
            reading.tone = .critical
            reading.status = Status(text: limitReached, showsFlame: true, tooltip: nil, isDeadline: false)
            reading.paceTooltip = limitReached
            return reading
        }

        guard let resetsAt = quota.resetsAt, let period = quota.window.duration,
              let pace = UsagePace.evaluate(used: used, limit: limit, resetsAt: resetsAt, period: period, now: now)
        else {
            reading.tone = bandTone(shareUsed: shareUsed)
            return reading
        }

        let projectedShare = pace.projectedUsage / limit
        let elapsed = min(max(1 - resetsAt.timeIntervalSince(now) / period, 0), 1)
        let tick = options.meterStyle == .left ? 1 - elapsed : elapsed
        // A window barely touched cannot be "cutting it close" whatever the arithmetic says: five
        // percent is where OpenUsage stopped trusting a projection enough to colour a bar with it.
        let trustsProjection = shareUsed >= 0.05

        switch pace.status {
        case .ahead:
            let left = Int(((1 - projectedShare) * 100).rounded())
            reading.tone = .normal
            reading.paceTooltip = "~\(left)% left at reset"
            if options.alwaysShowsPacing {
                reading.status = Status(text: "~\(left)% left at reset", showsFlame: false, tooltip: nil, isDeadline: false)
                reading.paceTick = tick
            }
        case .onTrack where trustsProjection:
            let spare = Int(((1 - projectedShare) * 100).rounded())
            let usedAtReset = Int((projectedShare * 100).rounded())
            reading.paceTick = tick
            reading.paceTooltip = "~\(usedAtReset)% used at reset"
            if spare < 1 {
                reading.tone = .critical
                reading.status = Status(text: nil, showsFlame: true, tooltip: reading.paceTooltip, isDeadline: false)
            } else {
                reading.tone = .warning
                reading.status = Status(
                    text: "~\(spare)% spare", showsFlame: false, tooltip: reading.paceTooltip, isDeadline: false
                )
            }
        case .behind where trustsProjection:
            reading.tone = .critical
            reading.paceTick = tick
            let over = Int(((projectedShare - 1) * 100).rounded())
            reading.paceTooltip = over >= 1 ? "~\(over)% over limit at reset" : "~100% used at reset"
            if let eta = UsagePace.secondsToRunOut(used: used, limit: limit, resetsAt: resetsAt, period: period, now: now) {
                let deadline = now.addingTimeInterval(eta)
                reading.status = Status(
                    text: UsageFormat.deadline(
                        "Limit", at: deadline, from: now, display: options.resetDisplay,
                        clock: options.timeFormat, calendar: options.calendar, locale: options.locale
                    ),
                    showsFlame: true,
                    tooltip: reading.paceTooltip,
                    isDeadline: true
                )
            } else {
                reading.status = Status(text: nil, showsFlame: true, tooltip: reading.paceTooltip, isDeadline: false)
            }
        case .onTrack, .behind:
            reading.tone = bandTone(shareUsed: shareUsed)
        }
        return reading
    }

    /// Ninety percent used is red and eighty is yellow, for a window with no clock to pace against.
    static func bandTone(shareUsed: Double) -> Tone {
        let percent = (shareUsed * 100).rounded()
        if percent >= 90 { return .critical }
        if percent >= 80 { return .warning }
        return .normal
    }

    static func figures(_ quota: AgentQuota) -> (used: Double, limit: Double)? {
        switch quota.measure {
        case .fraction(let fraction): return (fraction * 100, 100)
        case .counted(let used, let limit?, _): return (used, limit)
        case .counted, .unknown: return nil
        }
    }

    static func moneyUnit(_ quota: AgentQuota) -> String? {
        if case .counted(_, _, let unit) = quota.measure { return unit }
        return nil
    }

    static func isSpent(used: Double, limit: Double, money: Bool) -> Bool {
        let remaining = max(0, limit - used)
        if money { return (remaining * 100).rounded() == 0 }
        return (remaining / limit * 100).rounded() == 0
    }

    static func headline(used: Double, limit: Double, money: String?, style: UsageMeterStyle) -> String {
        let value = style == .left ? max(0, limit - used) : min(max(used, 0), limit)
        let figure = money.map { UsageFormat.money(value, code: $0) } ?? UsageFormat.percent(value / limit * 100)
        return "\(figure) \(style == .left ? "left" : "used")"
    }

    static func trayValue(used: Double, limit: Double, money: String?, style: UsageMeterStyle) -> String {
        let value = style == .left ? max(0, limit - used) : min(max(used, 0), limit)
        return money.map { UsageFormat.trayMoney(value, code: $0) } ?? UsageFormat.percent(value / limit * 100)
    }

    /// The whole row in one sentence, for VoiceOver, which reads neither the bar nor its colour.
    public func spoken(title: String) -> String {
        var parts = [title, headline == Self.emptyHeadline ? Self.noData : headline]
        if !trailing.isEmpty, trailing != Self.noData { parts.append(trailing) }
        if let text = status?.text { parts.append(text) } else if status?.showsFlame == true { parts.append("Running out") }
        return parts.joined(separator: ", ")
    }
}
