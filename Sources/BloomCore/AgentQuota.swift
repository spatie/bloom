import Foundation

/// How much of an agent provider's allowance has gone, and when it turns over.
///
/// **The shape is deliberately not an enum of session, weekly and monthly.** That was the obvious
/// modelling and it is wrong within one provider, never mind two. What the two CLIs that publish
/// anything actually send, measured rather than assumed:
///
/// - Claude Code emits one `rate_limit_event` per turn carrying exactly ONE window, named by a
///   string it invents: `five_hour` and `seven_day` are the two seen. There is no monthly window
///   on this protocol, and there is no way to ask for the others. So the windows Bloom knows about
///   accumulate over turns rather than arriving together, which is the whole reason they are rows
///   keyed by window rather than a fixed record with three slots.
/// - Codex sends `account/rateLimits/updated` after every turn with a `primary` and a `secondary`,
///   and it gives the window as a **duration in minutes** rather than as a name. The one measured
///   is 10080 minutes, which is a week, with `secondary` null.
///
/// A provider inventing a daily cap next month has to fit without a migration of this file, so a
/// window is a value with a key, a label and a duration, and the duration is optional because
/// Claude's names are the only thing it gives and a name Bloom has never seen carries no length.
public struct QuotaWindow: Sendable, Hashable, Codable, Identifiable {
    /// The provider's own token for the window, unchanged. This is the primary key half, so it
    /// must be whatever the payload said and never a Bloom invention.
    public var key: String
    /// What a person is shown. Derived from the duration when there is one, from the key when
    /// there is not.
    public var label: String
    /// How long the window is, in seconds, or nothing when the provider only named it and the
    /// name is not one Bloom can read.
    public var duration: TimeInterval?

    public var id: String { key }

    public init(key: String, label: String, duration: TimeInterval? = nil) {
        self.key = key
        self.label = label
        self.duration = duration
    }

    /// A window given as a length, which is how Codex reports one.
    public static func lasting(_ duration: TimeInterval, key: String) -> QuotaWindow {
        QuotaWindow(key: key, label: label(forSeconds: duration), duration: duration)
    }

    /// A window given only as a name, which is how Claude Code reports one.
    ///
    /// The name is read rather than looked up in a table of the two that exist today, so a
    /// `one_month` or a `thirty_day` shipping later arrives with a length and a readable label
    /// instead of a raw token. A name that does not parse still produces a usable row: the key
    /// tidied into words, and no duration, which is honest about what is known.
    public static func named(_ key: String) -> QuotaWindow {
        guard let duration = seconds(fromName: key) else {
            return QuotaWindow(key: key, label: humanised(key), duration: nil)
        }
        return QuotaWindow(key: key, label: label(forSeconds: duration), duration: duration)
    }

    private static let numerals: [String: Double] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        "fourteen": 14, "twenty": 20, "thirty": 30, "sixty": 60,
    ]

    private static let units: [String: TimeInterval] = [
        "minute": 60, "min": 60, "hour": 3600, "day": 86_400, "week": 604_800, "month": 2_592_000,
    ]

    /// `five_hour` and `seven_day` into seconds. Plurals and digits both, because a protocol that
    /// has already used two spellings of the same idea will use a third.
    static func seconds(fromName key: String) -> TimeInterval? {
        let parts = key.lowercased().split(whereSeparator: { $0 == "_" || $0 == "-" }).map(String.init)
        guard parts.count == 2 else { return nil }
        let count = numerals[parts[0]] ?? Double(parts[0])
        let unit = units[parts[1]] ?? units[String(parts[1].dropLast())]
        guard let count, let unit, count > 0 else { return nil }
        return count * unit
    }

    /// The words for a length. Whole weeks and whole days get their own noun because "7 days" is
    /// how a machine says "Week" and this is read at a glance.
    static func label(forSeconds seconds: TimeInterval) -> String {
        let rounded = seconds.rounded()
        switch rounded {
        case 604_800: return "Week"
        case 86_400: return "Day"
        case 2_592_000, 2_678_400: return "Month"
        default: break
        }
        if rounded >= 604_800, rounded.truncatingRemainder(dividingBy: 604_800) == 0 {
            return "\(Int(rounded / 604_800)) weeks"
        }
        if rounded >= 86_400, rounded.truncatingRemainder(dividingBy: 86_400) == 0 {
            let days = Int(rounded / 86_400)
            return days == 1 ? "Day" : "\(days) days"
        }
        if rounded >= 3600 {
            let hours = rounded / 3600
            let whole = Int(hours)
            let text = hours == Double(whole) ? "\(whole)" : String(format: "%.1f", hours)
            return whole == 1 && hours == 1 ? "Hour" : "\(text) hours"
        }
        return "\(Int((rounded / 60).rounded())) min"
    }

    /// `some_window` into "Some window", for a name nothing could read. Better than the raw token
    /// and it does not pretend to know a length.
    static func humanised(_ key: String) -> String {
        let words = key.split(whereSeparator: { $0 == "_" || $0 == "-" }).map(String.init)
        guard let first = words.first, !first.isEmpty else { return key }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst())
            .joined(separator: " ")
    }
}

/// What is known about how full a window is.
///
/// Three cases and not one number, because the three states are genuinely different and flattening
/// them loses the only one that matters. **Claude Code publishes `utilization` only once a warning
/// threshold has been passed**: below it the event says `"status":"allowed"` and carries the reset
/// time and nothing else. Storing that as zero would draw an empty bar and tell the user they had
/// used nothing, which is a lie the protocol never told.
public enum QuotaMeasure: Sendable, Hashable {
    /// A share of the allowance, 0 to 1. Both providers publish exactly this and nothing else.
    case fraction(Double)
    /// A count against a ceiling, for a provider that publishes real amounts. The ceiling is
    /// optional on purpose: a usage figure with no published limit is a thing to show, not an
    /// error, and it is what a metered provider without a plan cap would send.
    case counted(used: Double, limit: Double?, unit: String)
    /// The window exists and its reset time is known, but the provider has not said how much of
    /// it has gone.
    case unknown

    /// How full, as 0 to 1, when that can be worked out at all.
    public var fraction: Double? {
        switch self {
        case .fraction(let value): return value
        case .counted(let used, let limit, _):
            guard let limit, limit > 0 else { return nil }
            return used / limit
        case .unknown: return nil
        }
    }

    public var isKnown: Bool {
        if case .unknown = self { return false }
        return true
    }
}

/// One provider's allowance over one window, as last reported.
public struct AgentQuota: Sendable, Hashable, Identifiable {
    public var provider: AgentKind
    public var window: QuotaWindow
    public var measure: QuotaMeasure
    /// When the window turns over, when the provider says. Both measured providers do.
    public var resetsAt: Date?
    /// When Bloom last heard this. Kept so a late arriving report cannot overwrite a fresher one,
    /// and so a stale row can be recognised after the app has been shut for a week.
    public var observedAt: Date

    public var id: String { "\(provider.rawValue)/\(window.key)" }

    public init(
        provider: AgentKind,
        window: QuotaWindow,
        measure: QuotaMeasure,
        resetsAt: Date?,
        observedAt: Date
    ) {
        self.provider = provider
        self.window = window
        self.measure = measure
        self.resetsAt = resetsAt
        self.observedAt = observedAt
    }

    public var fraction: Double? { measure.fraction }

    /// Whether the window has already turned over since this was recorded.
    ///
    /// This is the whole answer to "what if the app was closed across a reset". A row saying 94%
    /// of a five hour window with a reset time last Tuesday is not 94% of anything; the allowance
    /// was refilled while nobody was watching and the only honest reading is that Bloom does not
    /// know. Expired rows are dropped on read rather than shown greyed, because a stale number
    /// next to a stale time is exactly the thing somebody acts on by mistake.
    public func hasExpired(at now: Date) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }
}

/// How close a window is to its wall, in the four steps the panel draws.
public enum QuotaSeverity: Int, Sendable, Hashable, Comparable, CaseIterable {
    case calm
    case warning
    case critical
    case spent

    public static func < (lhs: QuotaSeverity, rhs: QuotaSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The two thresholds are Claude Code's own. Its payload carries `surpassedThreshold: 0.75`
    /// alongside `"status":"allowed_warning"`, so 75 percent is where the provider itself starts
    /// to be concerned and Bloom has no business inventing a different number. The second is the
    /// last tenth, which is where a person still has time to change what they are doing.
    public static let warningAt = 0.75
    public static let criticalAt = 0.9

    public static func of(_ fraction: Double?) -> QuotaSeverity {
        guard let fraction else { return .calm }
        if fraction >= 1 { return .spent }
        if fraction >= criticalAt { return .critical }
        if fraction >= warningAt { return .warning }
        return .calm
    }
}

/// Everything Bloom knows about every provider's allowances, arranged for reading.
///
/// **What this decides, and why.** Four stacked bars is a dashboard, and this is a menu opened for
/// a second. The one thing a person wants from it is how close they are to the nearest wall and
/// when that wall lifts, so the board names a `headline`: the single fullest window across every
/// provider. Everything else stays as a compact ledger under it. When nothing has been reported
/// there is no headline and no ledger, and the menu says so in one line rather than drawing an
/// empty frame.
public struct QuotaBoard: Sendable, Hashable {
    /// One provider and its windows, shortest window first.
    public struct Provider: Sendable, Hashable, Identifiable {
        public var kind: AgentKind
        public var quotas: [AgentQuota]
        public var id: String { kind.rawValue }
    }

    public var providers: [Provider]

    public var isEmpty: Bool { providers.isEmpty }

    /// Every quota on the board, in the order the panel draws them.
    public var all: [AgentQuota] { providers.flatMap(\.quotas) }

    /// The window closest to its wall, which is what the panel leads with.
    ///
    /// Only a window whose fullness is actually known can be the headline. A window Claude has
    /// mentioned but not measured has no bar to draw and no fullness to compare, so leading with
    /// it would put "unknown" in the one line that is meant to answer the question.
    public var headline: AgentQuota? {
        all.filter { $0.fraction != nil }.max { ($0.fraction ?? 0) < ($1.fraction ?? 0) }
    }

    public var severity: QuotaSeverity { QuotaSeverity.of(headline?.fraction) }

    /// Groups, drops what has turned over, and sorts.
    ///
    /// Providers keep `AgentKind`'s own declaration order so the panel does not reshuffle itself
    /// when Codex happens to report first, and each provider's windows run shortest first, because
    /// the short window is the one that bites today.
    public static func make(from quotas: [AgentQuota], at now: Date = Date()) -> QuotaBoard {
        let live = quotas.filter { !$0.hasExpired(at: now) }
        let grouped = Dictionary(grouping: live, by: \.provider)
        let providers = AgentKind.allCases.compactMap { kind -> Provider? in
            guard let found = grouped[kind], !found.isEmpty else { return nil }
            return Provider(kind: kind, quotas: found.sorted(by: isShorter))
        }
        return QuotaBoard(providers: providers)
    }

    /// Shortest window first, and a window of unknown length last, since there is nothing to sort
    /// it by and it is the least likely to be the one that stops the next turn.
    private static func isShorter(_ lhs: AgentQuota, _ rhs: AgentQuota) -> Bool {
        switch (lhs.window.duration, rhs.window.duration) {
        case (let left?, let right?): return left == right ? lhs.window.key < rhs.window.key : left < right
        case (nil, _?): return false
        case (_?, nil): return true
        default: return lhs.window.key < rhs.window.key
        }
    }
}

/// How long until a window turns over, said the way a person would.
///
/// Coarse on purpose, and it never counts seconds. The menu is rebuilt when it opens and not while
/// it is up, so a live seconds figure would be wrong the moment it was drawn; and "in about 3
/// hours" is the whole of what anybody does with this. The floor is "in under a minute" rather
/// than "in 0 min", and a time already gone reads as "any moment now" because the provider's clock
/// and this one are not the same clock.
public enum QuotaCountdown {
    public static func phrase(until reset: Date, from now: Date = Date()) -> String {
        let seconds = reset.timeIntervalSince(now)
        guard seconds > 0 else { return "any moment now" }
        if seconds < 60 { return "in under a minute" }
        if seconds < 3600 {
            let minutes = Int((seconds / 60).rounded(.down))
            return "in \(minutes) min"
        }
        if seconds < 86_400 {
            let hours = Int((seconds / 3600).rounded(.down))
            let minutes = Int(((seconds - Double(hours) * 3600) / 60).rounded(.down))
            return minutes == 0 ? "in \(hours)h" : "in \(hours)h \(minutes)m"
        }
        let days = Int((seconds / 86_400).rounded(.down))
        let hours = Int(((seconds - Double(days) * 86_400) / 3600).rounded(.down))
        if days >= 3 || hours == 0 { return "in \(days)d" }
        return "in \(days)d \(hours)h"
    }
}
