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
            guard let minutes = window["windowDurationMins"]?.doubleValue, minutes > 0 else { return nil }
            let measure: QuotaMeasure = window["usedPercent"]?.doubleValue
                .map { .fraction($0 / 100) } ?? .unknown
            return AgentQuota(
                provider: provider,
                window: .lasting(minutes * 60, key: slot),
                measure: measure,
                resetsAt: window["resetsAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0) },
                observedAt: now
            )
        }
    }
}
