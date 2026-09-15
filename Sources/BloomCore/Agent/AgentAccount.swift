import Foundation

/// What a provider says about the account itself rather than about a window: which plan it is on,
/// and for Codex, the balances that sit beside the windows.
///
/// **Kept apart from `AgentQuota` because none of it turns over.** A quota row is a window with a
/// reset time, stored so a late report cannot overwrite a fresher one and dropped once it has
/// reset. A plan name has no reset and no window, and a credit balance is a wallet rather than a
/// wall. Folding either into the quota table would mean inventing a window for it, and every rule
/// that table is built on (expiry, merge, pacing) would then have to learn to skip the invented
/// ones. So these live in memory on the app model, refreshed by the same ask that refreshes the
/// windows, and a relaunch shows them again within the second that ask takes.
///
/// Both CLIs already send all of this in the answers Bloom asks for, and Bloom used to read it and
/// drop it: `subscription_type` in Claude Code's `get_usage`, and `planType`, `credits` and
/// `rateLimitResetCredits` in Codex's `account/rateLimits/read`.
public struct AgentAccount: Sendable, Hashable {
    public var provider: AgentKind
    /// The plan as a person would say it: "Max", "Pro 20x", "Business Premium".
    public var plan: String?
    /// Codex's credit balance, when the account reports one.
    public var credits: Credits?
    /// Codex's free resets, when the account reports any.
    public var resetCredits: ResetCredits?
    public var observedAt: Date

    public struct Credits: Sendable, Hashable {
        public var balance: Double
        public var isUnlimited: Bool

        public init(balance: Double, isUnlimited: Bool = false) {
            self.balance = balance
            self.isUnlimited = isUnlimited
        }
    }

    public struct ResetCredits: Sendable, Hashable {
        public var available: Int
        /// When each available reset lapses, soonest first.
        public var expiries: [Date]

        public init(available: Int, expiries: [Date] = []) {
            self.available = available
            self.expiries = expiries
        }
    }

    public init(
        provider: AgentKind,
        plan: String? = nil,
        credits: Credits? = nil,
        resetCredits: ResetCredits? = nil,
        observedAt: Date
    ) {
        self.provider = provider
        self.plan = plan
        self.credits = credits
        self.resetCredits = resetCredits
        self.observedAt = observedAt
    }
}

/// Reads an `AgentAccount` out of the answer a quota source brought back.
///
/// Dispatch is on the shape of the payload, like `AgentQuotaAdapters`, so the same bytes that
/// adapter reads are read here too and neither source has to say which provider it is.
public enum AgentAccountReader {
    public static func account(from data: Data, at now: Date = Date()) -> AgentAccount? {
        guard let line = JSONValue.parse(data) else { return nil }
        return claudeCode(line, at: now) ?? codex(line, at: now)
    }

    /// Claude Code's `get_usage` answer. Recognised by the two fields only that answer carries.
    static func claudeCode(_ line: JSONValue, at now: Date) -> AgentAccount? {
        let payload = line["response"]?["response"] ?? line
        guard payload["session"] != nil || payload["rate_limits_available"] != nil else { return nil }
        return AgentAccount(
            provider: .claudeCode,
            plan: payload["subscription_type"]?.stringValue.flatMap(claudePlan),
            observedAt: now
        )
    }

    /// Codex's `account/rateLimits/read` answer, or the notification of the same snapshot.
    static func codex(_ line: JSONValue, at now: Date) -> AgentAccount? {
        let codex = line["codex"] ?? line
        let body = codex["result"] ?? codex["params"] ?? codex
        guard let limits = body["rateLimits"] else { return nil }

        var credits: AgentAccount.Credits?
        if let raw = limits["credits"] {
            let unlimited = raw["unlimited"]?.boolValue ?? false
            // The balance arrives as a string ("0") on the wire measured, and as a number in
            // Codex's own schema, so both are read.
            let balance = raw["balance"]?.doubleValue
                ?? raw["balance"]?.stringValue.flatMap(Double.init)
                ?? (raw["hasCredits"]?.boolValue == false ? 0 : nil)
            if let balance { credits = .init(balance: max(0, balance.rounded(.down)), isUnlimited: unlimited) }
        }

        var resets: AgentAccount.ResetCredits?
        if let raw = body["rateLimitResetCredits"], let count = raw["availableCount"]?.intValue, count >= 0 {
            let expiries = (raw["credits"]?.arrayValue ?? [])
                .filter { ($0["status"]?.stringValue ?? "available") == "available" }
                .compactMap { $0["expiresAt"]?.doubleValue.map(Date.init(timeIntervalSince1970:)) }
                .sorted()
            resets = .init(available: count, expiries: expiries)
        }

        return AgentAccount(
            provider: .codex,
            plan: limits["planType"]?.stringValue.flatMap(codexPlan),
            credits: credits,
            resetCredits: resets,
            observedAt: now
        )
    }

    /// `max` into "Max". The CLI's answer carries no tier multiplier, so a Max 20x account reads
    /// as Max: a name Bloom would have to guess the rest of is a name it does not print.
    public static func claudePlan(_ raw: String) -> String? {
        let words = raw.split(whereSeparator: { $0 == "_" || $0 == " " })
        guard !words.isEmpty else { return nil }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
    }

    /// Codex's plan tokens, with the three that do not read as words spelled the way OpenAI's own
    /// pricing page names them.
    public static func codexPlan(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "": return nil
        case "prolite": return "Pro 5x"
        case "pro": return "Pro 20x"
        case "self_serve_business_prolite": return "Business Premium"
        default:
            return raw.split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }
}
