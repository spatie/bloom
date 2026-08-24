import Foundation

/// How far ahead of its own clock a window is.
///
/// **Fullness on its own cannot tell two situations apart, and they are not the same situation.**
/// A weekly window at 95 percent with six days still to run is somebody who cannot work this week.
/// A five hour window at 95 percent that lifts in twenty minutes is somebody who makes a cup of
/// tea. The panel led with whichever number was biggest and said nothing about the difference,
/// which is the one thing a person opens it to find out.
///
/// A window refills on a clock, so the honest reading is the share used against the share of the
/// window already gone. Below the line the allowance is outlasting the clock; above it, it is not,
/// and `overspend` is how far above.
///
/// The projection is linear and that is a real assumption: nobody's usage is flat, and a morning
/// of heavy turns followed by an afternoon of reading does not run out when this says it will. It
/// is stated as "at this rate" for exactly that reason. The alternative on offer was no warning at
/// all until the wall, which is worse than a stated estimate a person can discount.
public struct QuotaPace: Sendable, Hashable {
    /// The share of the allowance gone, 0 to 1.
    public var used: Double
    /// The share of the window gone, 0 to 1.
    public var elapsed: Double
    /// Seconds until the window lifts.
    public var remaining: TimeInterval

    /// How far ahead of the clock, or zero when the allowance is keeping up.
    public var overspend: Double { max(0, used - elapsed) }

    /// Seconds until the allowance runs out at the rate so far, or nothing when it does not run
    /// out before the window lifts.
    public var runsOutIn: TimeInterval?

    /// A window has to be this far into itself before its rate means anything.
    ///
    /// Two heavy turns in the first ten minutes of a week is a rate that projects catastrophe by
    /// Tuesday and is pure noise. A tenth of the window is where the arithmetic stops being
    /// dominated by whatever happened to be the first thing anybody ran.
    public static let minimumElapsed = 0.1

    /// How far inside the window the forecast has to land before it is worth a sentence. See
    /// `runsOut`.
    public static let clearance = 0.75

    /// The reading for one window, or nothing when the window does not carry enough to take one.
    ///
    /// Three things are needed and any of them can genuinely be missing: a measured fullness (a
    /// window Claude has mentioned but not measured has none), a reset time, and a stated length.
    /// Nothing is inferred in their absence; the row simply has no pace and says nothing about one.
    public static func of(_ quota: AgentQuota, at now: Date) -> QuotaPace? {
        guard let used = quota.fraction,
              let resetsAt = quota.resetsAt,
              let duration = quota.window.duration, duration > 0
        else { return nil }

        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        let elapsed = min(max(1 - remaining / duration, 0), 1)

        return QuotaPace(
            used: used,
            elapsed: elapsed,
            remaining: remaining,
            runsOutIn: runsOut(used: used, elapsed: elapsed, duration: duration, remaining: remaining)
        )
    }

    /// Seconds until the allowance is gone, at the rate measured so far.
    ///
    /// Nothing is returned for a window already spent (there is no forecast to make), for one
    /// nothing has been used from (the rate is zero and the answer is never), for one too early to
    /// read, or for one whose forecast lands after the window lifts, which is the ordinary case and
    /// the one that must not produce a sentence.
    static func runsOut(
        used: Double,
        elapsed: Double,
        duration: TimeInterval,
        remaining: TimeInterval
    ) -> TimeInterval? {
        guard used > 0, used < 1, elapsed >= minimumElapsed else { return nil }
        let secondsSoFar = duration * elapsed
        let seconds = (1 - used) * secondsSoFar / used
        // Comfortably before the window lifts, not merely before it. Sixty percent of a week gone
        // with fifty seven percent of the week behind it forecasts running out two and a half days
        // in against a window that lifts in three, which is arithmetically true, three points of
        // overspend, and on screen almost always. A sentence that is nearly always there is a
        // sentence nobody reads, so it has to clear the reset by a quarter of the window before it
        // is worth saying.
        guard seconds < remaining * clearance else { return nil }
        return seconds
    }
}

/// Every sentence the limits panel says, and every number it prints.
///
/// **In the core because a sentence taken inside a view is a sentence nothing can test.** The panel
/// used to phrase the headline's countdown as "Lifts in 3d" and the ledger's as "in 3h 13m", which
/// is one idea in two voices two rows apart, and neither of them was reachable from a test. One
/// voice now, decided here: every window says when it lifts, in the same words, whatever size it is
/// drawn at.
public enum QuotaPhrase {
    /// The heading over the panel. The owner's word, and the shorter one.
    public static let heading = "LIMITS"

    /// Said where a percentage would go, for a window the provider has not measured.
    ///
    /// It has to be words rather than "0%", and the row it sits on has to draw no track, because
    /// the two facts are different: Claude Code publishes a figure only once a window has passed
    /// its warning threshold, so early in a five hour window nobody has said. A zero is a
    /// measurement. This is the absence of one.
    public static let notReported = "not reported"

    /// Who and which window. The one string the row is never allowed to truncate.
    public static func title(for quota: AgentQuota) -> String {
        "\(quota.provider.label) · \(quota.window.label)"
    }

    /// The figure, or the words for a window nobody has measured.
    ///
    /// Rounded down, never up. Rounding 0.999 to "100%" says a window is spent while there is
    /// still room in it, which is the one direction this number must not be wrong in.
    public static func figure(for quota: AgentQuota) -> String {
        guard let fraction = quota.fraction else { return notReported }
        return "\(Int((min(max(fraction, 0), 1) * 100).rounded(.down)))%"
    }

    /// The line under the lane: when the window lifts, and, when the rate so far says the allowance
    /// will not last that long, what it says.
    ///
    /// **The forecast is what answers the thing fullness cannot.** Ninety five percent of a weekly
    /// with six days to run and ninety five percent of a five hour window that lifts in twenty
    /// minutes wear the same colour, correctly, because the owner's ramp is about utilisation and a
    /// colour that argued with it would be two rules. The difference between those two situations
    /// is time, so time says it, in words. `QuotaBoard.forecastable` picks the one row per panel
    /// that carries it, because a sentence repeated down a column is a paragraph and a paragraph
    /// in a menu is not read.
    public static func footnote(
        for quota: AgentQuota,
        at now: Date,
        forecasting: Bool = false,
        locale: Locale = .current
    ) -> String {
        var parts: [String] = []
        if case .counted(let used, let limit, let unit) = quota.measure {
            parts.append(spend(used: used, limit: limit, code: unit, locale: locale))
        }
        if let resetsAt = quota.resetsAt {
            parts.append("Lifts \(QuotaCountdown.phrase(until: resetsAt, from: now))")
        }
        if forecasting, let seconds = QuotaPace.of(quota, at: now)?.runsOutIn {
            parts.append("at this rate it runs out \(QuotaCountdown.rough(after: seconds))")
        }
        // Each clause is a sentence, so each one starts as one. Joined without a full stop at the
        // end: this sits under a lane in a menu, where a trailing stop reads as a stray mark.
        return parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: ". ")
    }

    /// Money, for the one row that is money rather than a window.
    ///
    /// `Locale` is a parameter rather than read, so a test can pin it. A provider that states an
    /// amount with no ceiling gets the amount alone, which is what a metered account with no cap
    /// would send and is a thing to show rather than an error.
    static func spend(used: Double, limit: Double?, code: String, locale: Locale) -> String {
        guard let limit else { return "\(money(used, code: code, locale: locale)) so far" }
        return "\(money(used, code: code, locale: locale)) of "
            + "\(money(limit, code: code, locale: locale))"
    }

    static func money(_ amount: Double, code: String, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        formatter.currencyCode = code.uppercased()
        return formatter.string(from: NSNumber(value: amount))
            ?? String(format: "%.2f %@", amount, code.uppercased())
    }
}

/// One row of the limits panel, decided here rather than in the view.
///
/// The panel draws a title, a figure, a lane of some length in some colour and a line of words.
/// Every one of those four is a decision, so every one of them is made in a place a test can reach,
/// and `QuotaPanel` is left holding nothing but ink and geometry.
public struct QuotaLine: Sendable, Hashable, Identifiable {
    /// The same two halves `AgentQuota.id` is made of, kept apart so this carries no bare string
    /// id of its own. One provider's one window is one row, and that is the identity.
    public var provider: AgentKind
    public var windowKey: String
    public var id: String { "\(provider.rawValue)/\(windowKey)" }

    public var title: String
    public var figure: String
    /// How much of the lane is filled, 0 to 1, or nothing when nobody has said. A row with nothing
    /// here draws no track at all: see `QuotaPhrase.notReported`.
    public var fill: Double?
    /// Where on the ramp this row sits, or nothing when nobody has measured it.
    ///
    /// Optional rather than `.calm`, and that is the whole point. `QuotaSeverity.of(nil)` answers
    /// calm, which is correct for a board with nothing on it and wrong for a row: a window Claude
    /// has mentioned but not measured would land in the same bucket as one measured at four
    /// percent, and the view would paint it the quiet ink as though somebody had checked. Nobody
    /// has. A row with nothing here draws no lane and says so in words.
    public var severity: QuotaSeverity?
    public var footnote: String

    /// The whole row in one sentence, for a reader who cannot see the lane.
    ///
    /// The lane IS the row for a sighted reader: the figure says how much and the tint says
    /// whether that is a problem. Neither of those reaches VoiceOver, which read the title and the
    /// figure as two unrelated labels and never mentioned the severity at all, because the panel
    /// carried no accessibility modifier anywhere in the file.
    ///
    /// Built here rather than in the view for the reason the rest of this type is here: a sentence
    /// a view owns is a sentence nothing can read back.
    public var spoken: String {
        var parts = [title, figure]
        if let word = severity?.word { parts.append(word) }
        if !footnote.isEmpty { parts.append(footnote) }
        return parts.joined(separator: ", ")
    }

    public init(
        provider: AgentKind,
        windowKey: String,
        title: String,
        figure: String,
        fill: Double?,
        severity: QuotaSeverity?,
        footnote: String
    ) {
        self.provider = provider
        self.windowKey = windowKey
        self.title = title
        self.figure = figure
        self.fill = fill
        self.severity = severity
        self.footnote = footnote
    }

    public static func of(
        _ quota: AgentQuota,
        at now: Date,
        forecasting: Bool = false,
        locale: Locale = .current
    ) -> QuotaLine {
        let fraction = quota.fraction
        return QuotaLine(
            provider: quota.provider,
            windowKey: quota.window.key,
            title: QuotaPhrase.title(for: quota),
            figure: QuotaPhrase.figure(for: quota),
            fill: fraction.map { min(max($0, 0), 1) },
            severity: fraction.map(QuotaSeverity.of),
            footnote: QuotaPhrase.footnote(
                for: quota, at: now, forecasting: forecasting, locale: locale
            )
        )
    }
}
