import Foundation

/// Turns one provider's rate limit payload into `AgentQuota` values, and nothing else.
///
/// **This is the seam a third provider is added at.** Write a type conforming to this, return the
/// windows that provider publishes, return an empty array for a payload that is not yours, and add
/// the type to `AgentQuotaAdapters.all`. Nothing else in Bloom changes: the store is keyed by
/// provider and window key, the board groups by `AgentKind`, and the panel draws whatever it is
/// given. A provider that publishes no allowance at all needs no adapter and is not an error; two
/// of the four CLIs Bloom detects are exactly that, and they contribute nothing rather than
/// contributing a row that says "unknown".
public protocol AgentQuotaAdapter: Sendable {
    static var provider: AgentKind { get }

    /// The windows carried by one `rate_limit_event` line, or nothing when the line is another
    /// provider's. `now` is passed in rather than read, so the tests are not racing a clock.
    static func quotas(from line: JSONValue, at now: Date) -> [AgentQuota]
}

/// Every adapter Bloom has, and the one call the app makes.
public enum AgentQuotaAdapters {
    /// Order does not matter: each adapter recognises its own payload and declines the rest.
    public static let all: [any AgentQuotaAdapter.Type] = [
        ClaudeCodeQuotaAdapter.self,
        ClaudeCodeUsageAdapter.self,
        CodexQuotaAdapter.self,
    ]

    /// Reads a `rate_limit_event` line from any backend.
    ///
    /// Dispatch is on the shape of the payload rather than on which session it arrived from,
    /// because `CodexTranslation.rateLimitLine` already re-wraps Codex's own event as a
    /// `rate_limit_event` with the original nested under `codex`. One reader therefore handles
    /// both runners without either of them having to say who they are, and a line neither adapter
    /// recognises produces no rows instead of an error.
    public static func quotas(fromRateLimitEvent data: Data, at now: Date = Date()) -> [AgentQuota] {
        guard let line = JSONValue.parse(data) else { return [] }
        return all.flatMap { $0.quotas(from: line, at: now) }
    }
}

/// Claude Code's `rate_limit_event`.
///
/// Measured against the real binary on 23 August 2026, one turn of `claude -p --output-format
/// stream-json --model haiku`, which produced exactly this:
///
/// ```json
/// {"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1787508600,
///  "rateLimitType":"five_hour","overageStatus":"rejected",
///  "overageDisabledReason":"org_level_disabled","isUsingOverage":false},"uuid":"...","session_id":"..."}
/// ```
///
/// and against `Tests/fixtures/session-basic.jsonl`, recorded earlier on a busier account:
///
/// ```json
/// {"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":1787122800,
///  "rateLimitType":"seven_day","utilization":0.77,"isUsingOverage":false,"surpassedThreshold":0.75}}
/// ```
///
/// Three things follow from that pair, and all three shaped the model.
///
/// **One window per event.** The line names a single `rateLimitType`. There is no array and no
/// second window, so what Bloom knows is whatever has been mentioned since the last reset, which
/// is why the store keys on the window rather than replacing a provider's whole record.
///
/// **`utilization` is absent below the warning threshold.** The first payload has no usage figure
/// at all; the second has one and a `surpassedThreshold` of 0.75 next to it. So the number arrives
/// only once the account is near the wall. That is stored as `.unknown`, never as zero.
///
/// **There is no monthly window.** `five_hour` and `seven_day` are what this protocol emits. Bloom
/// shows those two and says nothing about a month, because a month is not a thing Claude Code
/// reports.
public enum ClaudeCodeQuotaAdapter: AgentQuotaAdapter {
    public static let provider = AgentKind.claudeCode

    public static func quotas(from line: JSONValue, at now: Date) -> [AgentQuota] {
        guard let info = line["rate_limit_info"], let type = info["rateLimitType"]?.stringValue else {
            return []
        }
        let measure: QuotaMeasure = info["utilization"]?.doubleValue.map { .fraction($0) } ?? .unknown
        return [AgentQuota(
            provider: provider,
            window: .named(type),
            measure: measure,
            resetsAt: info["resetsAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0) },
            observedAt: now
        )]
    }
}

/// Codex's `account/rateLimits/updated`, as re-wrapped by `CodexTranslation.rateLimitLine`.
///
/// Measured, and recorded in `Tests/fixtures/codex-turn.ndjson`:
///
/// ```json
/// {"rateLimits":{"limitId":"codex","limitName":null,
///  "primary":{"usedPercent":6,"windowDurationMins":10080,"resetsAt":1787298966},
///  "secondary":null,"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},
///  "individualLimit":null,"spendControlReached":null,"planType":"prolite",
///  "rateLimitReachedType":null}}
/// ```
///
/// Better information than Claude's in two ways and worse in one. Better: the usage percentage is
/// always there rather than only near the wall, and the window arrives as a **length in minutes**
/// so nothing has to be inferred from a name. Worse: the windows are called `primary` and
/// `secondary` and nothing more, so the key stored is that word and the label comes from the
/// duration. `secondary` is null on this account, which is why one window shows rather than two;
/// a null slot is skipped rather than stored as an empty one.
///
/// `credits`, `planType` and `spendControlReached` are read and deliberately dropped. Credits are
/// a balance rather than a window, they have no reset time, and a panel about how close you are to
/// a wall is the wrong place for a wallet.
public enum CodexQuotaAdapter: AgentQuotaAdapter {
    public static let provider = AgentKind.codex

    public static func quotas(from line: JSONValue, at now: Date) -> [AgentQuota] {
        // `CodexClient` hands the whole notification through, so the limits sit under `params` on
        // the wire and under neither key once `CodexTranslation` has unwrapped it. Both spellings
        // are read because the fixtures carry the first and the runner produces the second.
        let codex = line["codex"] ?? line
        guard let limits = codex["params"]?["rateLimits"] ?? codex["rateLimits"] else { return [] }
        return ["primary", "secondary"].compactMap { slot in
            guard let window = limits[slot] else { return nil }
            // Only `usedPercent` is required on Codex's own `RateLimitWindow`. A rolling update
            // carrying a percentage and neither a length nor a reset time used to be declined
            // here, which threw away the one number this panel exists to show. It is now a row
            // with the length missing, and `QuotaMerge` puts back the length the last full
            // snapshot gave. A row that has never had a snapshot behind it reads as a window with
            // no stated length, which is the truth.
            let minutes = window["windowDurationMins"]?.doubleValue.flatMap { $0 > 0 ? $0 : nil }
            let measure: QuotaMeasure = window["usedPercent"]?.doubleValue
                .map { .fraction($0 / 100) } ?? .unknown
            return AgentQuota(
                provider: provider,
                window: minutes.map { QuotaWindow.lasting($0 * 60, key: slot) }
                    ?? QuotaWindow(key: slot, label: QuotaWindow.humanised(slot)),
                measure: measure,
                resetsAt: window["resetsAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0) },
                observedAt: now
            )
        }
    }
}

/// Claude Code's answer to a `get_usage` control request, which is the same account's allowances
/// stated all at once instead of one window per turn.
///
/// Measured against 2.1.241 on 23 August 2026. The CLI's own schema for the payload, lifted out of
/// the binary rather than guessed, is:
///
/// ```
/// session: { total_cost_usd, total_api_duration_ms, total_duration_ms, ... }
/// subscription_type: string | null
/// rate_limits_available: boolean   // false for an API key, Bedrock, Vertex, or a missing scope
/// rate_limits: {                   // null when the above is false
///   five_hour?:            { utilization: number|null, resets_at: string|null } | null
///   seven_day?:            ...
///   seven_day_oauth_apps?: ...
///   seven_day_opus?:       ...
///   seven_day_sonnet?:     ...
///   model_scoped?: [{ display_name, utilization, resets_at }]
///   extra_usage?:  { is_enabled, monthly_limit, used_credits, utilization, currency }
/// } | null
/// ```
///
/// **Three differences from `rate_limit_event`, and every one of them has bitten something.**
/// `utilization` here is a percentage from 0 to 100, where the notification sends a fraction from
/// 0 to 1, so a five hour window at three quarters is `75` on this wire and `0.75` on the other.
/// `resets_at` is an ISO 8601 string where the notification sends unix seconds. And this answer
/// names five windows where the notification names one, which is the entire point: `five_hour` and
/// `seven_day` are what a turn happens to mention, and the other three exist all along.
///
/// The keys are kept exactly as the CLI spells them, which is what makes an answer and a
/// notification land on the same row rather than on two rows describing one window.
///
/// `model_scoped` and `extra_usage` are read and deliberately dropped, for the reason
/// `CodexQuotaAdapter` drops `credits`. A per model breakdown is a report, and an extra usage
/// balance is a wallet; this panel answers how close the nearest wall is.
///
/// **`rate_limits_available: false` is not an error and not a zero.** It is an account that has no
/// plan limits to report, which is every API key, Bedrock and Vertex session. No rows are produced
/// and nothing is written, so the panel keeps saying nothing rather than drawing an empty bar.
public enum ClaudeCodeUsageAdapter: AgentQuotaAdapter {
    public static let provider = AgentKind.claudeCode

    /// The five windows the CLI's schema names, in the order the panel would sort them anyway.
    /// Read from a list rather than by walking the object's keys so a field that arrives later
    /// with a shape nobody has seen cannot become a row nobody can label.
    static let windowKeys = [
        "five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "seven_day_oauth_apps",
    ]

    public static func quotas(from line: JSONValue, at now: Date) -> [AgentQuota] {
        // Both spellings, for the same reason `CodexQuotaAdapter` reads two: the source hands the
        // control response's inner payload straight through, and a recorded fixture keeps the
        // whole envelope.
        let payload = line["response"]?["response"] ?? line
        guard payload["rate_limits_available"]?.boolValue == true,
              let limits = payload["rate_limits"]
        else { return [] }

        return windowKeys.compactMap { key in
            guard let window = limits[key] else { return nil }
            // A window the account has but has not used yet arrives with a null utilization, which
            // is `.unknown` and not zero, exactly as it is on the notification path.
            let measure: QuotaMeasure = window["utilization"]?.doubleValue
                .map { .fraction($0 / 100) } ?? .unknown
            return AgentQuota(
                provider: provider,
                window: .named(key),
                measure: measure,
                resetsAt: window["resets_at"]?.stringValue.flatMap(Self.date(fromISO:)),
                observedAt: now
            )
        }
    }

    /// ISO 8601, with and without fractional seconds, because a timestamp that gains milliseconds
    /// in a later build must not silently stop parsing and take a window's reset time with it.
    static func date(fromISO text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}
