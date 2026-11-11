import Foundation

/// A turn that ran into the account's allowance, and when it is safe to pick it up again.
///
/// **Asked for as "a button to continue working in a thread when the session limit is reset,
/// based on a timer and a usage check", and both halves are needed.** The timer alone is the reset
/// time the provider stated, and a reset time is a promise about a clock on somebody else's
/// server: sending the moment it passes is sending into a window that may not have turned over
/// yet, and the turn fails again with the same sentence. The usage check alone has no idea when to
/// look. So the resume waits for the latest stated reset of every spent window, and then for a
/// reading of the account taken after that reset which shows nothing spent. The once a minute poll
/// in `QuotaPollSchedule` is what produces that reading, and a resume that is `checking` only
/// nudges the app's one asker, which keeps its own floor.
///
/// **What a limit hit looks like was read from real sessions, not guessed.** Claude Code 2.1.276
/// ending a turn on the five hour window wrote an assistant message saying "You've hit your
/// session limit · resets 11:40pm (Europe/Brussels)" with `apiErrorStatus: 429` and
/// `quotaLimits.status: "rejected"`, and its `result` line carries `api_error_status` on the same
/// terms. Codex states it as `codexErrorInfo: "usageLimitExceeded"` on the failed turn, which
/// `CodexTranslation` carries onto its result as `codex_error_info`. Both are tokens, so nothing
/// here reads anybody's prose, and in particular nothing parses "11:40pm" out of a sentence whose
/// wording and time zone are the CLI's to change.
///
/// Pure, so every one of those decisions is tested against a clock the test holds.
public struct LimitResume: Sendable, Hashable {
    /// What to do on this look.
    public enum Step: Sendable, Hashable {
        /// A spent window has said when it turns over, and that has not happened yet.
        case waitUntil(Date)
        /// The reset has passed, or none was stated, and no reading taken since shows the account
        /// has room again. The next poll decides.
        case checking
        /// A reading taken after the reset shows nothing spent.
        case go
    }

    /// How often a waiting resume looks again.
    ///
    /// A look is a filter over rows already in memory and costs nothing. It is short rather than
    /// one long sleep until the reset because a Mac asleep across the reset time wakes with a
    /// sleep that has not finished, and half the poll interval means the reading that arrives
    /// after the reset is acted on within a minute of arriving.
    public static let interval: TimeInterval = 30

    /// What is sent when the allowance is back. Addressed to the agent, which reads it as the next
    /// message of the same conversation and has everything it was doing still in its context.
    public static let prompt = "Continue where you left off."

    public let provider: AgentKind
    /// When the turn failed. A reading older than this describes the account before the wall.
    public let hitAt: Date
    /// The latest reset any spent window has named. Remembered, because a window is dropped from
    /// the quotas the moment its reset passes and the time it named has to outlive it.
    public private(set) var notBefore: Date?

    public init(provider: AgentKind, hitAt: Date) {
        self.provider = provider
        self.hitAt = hitAt
    }

    /// Whether a failed turn failed on the allowance rather than on anything else.
    ///
    /// A 429 that the CLI could retry never reaches a result: it is retried inside the turn and
    /// announced as `api_retry`, which `AgentRetry` reads. One that ends the turn is the wall.
    public static func isLimitHit(_ result: AgentResult) -> Bool {
        guard !result.succeeded, let line = JSONValue.parse(result.raw) else { return false }
        if line["api_error_status"]?.intValue == 429 { return true }
        return line["codex_error_info"]?.stringValue == CodexErrorInfo.usageLimitExceeded
    }

    /// Decides this look, from every quota Bloom holds, and remembers any reset it learns.
    ///
    /// Mutating, so it cannot be called inside `#expect`: lift it into a `let` first.
    public mutating func step(quotas: [AgentQuota], at now: Date) -> Step {
        // A spent credit balance never resets and stops being reported once the org disables it,
        // so counting it kept the resume checking forever. The plan windows alone decide.
        let live = quotas.filter {
            $0.provider == provider && !$0.window.isCreditBalance && !$0.hasExpired(at: now)
        }
        let spent = live.filter { QuotaSeverity.of($0.fraction) == .spent }

        if let wall = spent.compactMap(\.resetsAt).max() {
            notBefore = max(notBefore ?? wall, wall)
        }
        if let notBefore, now < notBefore { return .waitUntil(notBefore) }
        // Spent, and nothing said when it lifts. Only a new reading of that window can clear it.
        if !spent.isEmpty { return .checking }

        let since = max(hitAt, notBefore ?? hitAt)
        guard live.contains(where: { $0.observedAt > since }) else { return .checking }
        return .go
    }
}

/// Codex's own tokens for why a turn failed, as far as Bloom reads them.
public enum CodexErrorInfo {
    public static let usageLimitExceeded = "usageLimitExceeded"

    /// The token out of `error.codexErrorInfo`, which is a bare string for a variant with nothing
    /// in it and a one key object for one that carries fields. The key is the token either way.
    public static func token(in error: JSONValue?) -> String? {
        guard let info = error?["codexErrorInfo"] else { return nil }
        if let token = info.stringValue { return token }
        guard let object = info.objectValue, object.count == 1 else { return nil }
        return object.keys.first
    }
}

extension LimitResume {
    /// Whether Bloom can read this provider's allowance at all. A resume that can never see a
    /// reading can never go, so it is not offered. These are the providers `AgentQuotaSources`
    /// asks; a third one added there belongs here too.
    public static func canWatch(_ provider: AgentKind) -> Bool {
        provider == .claudeCode || provider == .codex
    }
}

extension LimitResume.Step {
    /// The line under a failed turn while the resume is waiting.
    public func sentence(now: Date = Date(), timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        switch self {
        case .waitUntil(let reset):
            var time = Date.FormatStyle(date: .omitted, time: .shortened)
            time.timeZone = timeZone
            time.locale = locale
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            if calendar.isDate(reset, inSameDayAs: now) {
                return "Continues after the limit resets at \(reset.formatted(time))."
            }
            // A weekly reset days away read as an hour already passed when only the time was shown.
            var day = Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated)
            day.timeZone = timeZone
            day.locale = locale
            return "Continues after the limit resets on \(reset.formatted(day)) at \(reset.formatted(time))."
        case .checking:
            return "Continues as soon as a usage reading shows the limit has reset."
        case .go:
            return "Continuing."
        }
    }
}
