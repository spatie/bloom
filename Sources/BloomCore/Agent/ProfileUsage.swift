import Foundation

/// Allowances for one configured CLI home. These never enter the default account's quota store,
/// severity, notices or automatic resume decisions.
public struct ProfileUsage: Sendable, Hashable, Identifiable {
    public var profile: AgentAccountProfile
    public var quotas: [AgentQuota]
    public var account: AgentAccount?
    public var id: AgentAccountProfileID { profile.id }

    public init(profile: AgentAccountProfile, quotas: [AgentQuota], account: AgentAccount? = nil) {
        self.profile = profile
        self.quotas = quotas
        self.account = account
    }
}

extension AgentQuotaSources {
    /// Each home is asked concurrently, but results retain the order chosen in Settings. A failed
    /// ask keeps the previous reading; an answer with no windows or plan means signed out.
    public static func report(
        profiles: [AgentAccountProfile],
        known: [ProfileUsage] = [],
        home: @Sendable (AgentAccountProfile) -> String,
        environment: [String: String] = Shell.environment(),
        at now: Date = Date(),
        makeSource: @Sendable (AgentKind, [String: String]) -> (any AgentQuotaSource)? = accountSource
    ) async -> [ProfileUsage] {
        let previous = Dictionary(known.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return await withTaskGroup(of: ProfileUsage?.self) { group in
            for profile in profiles {
                let environment = AgentAccountEnvironment.applying(
                    kind: profile.kind, home: home(profile), to: environment
                )
                guard let source = makeSource(profile.kind, environment) else { continue }
                let old = previous[profile.id]
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    guard let payload = await source.read() else {
                        return old.map { ProfileUsage(profile: profile, quotas: $0.quotas, account: $0.account) }
                    }
                    let quotas = AgentQuotaAdapters.quotas(fromRateLimitEvent: payload, at: now)
                    var account = AgentAccountReader.account(from: payload, at: now)
                    guard !quotas.isEmpty || account?.plan != nil else { return nil }
                    if var current = account, let prior = old?.account {
                        current.plan = current.plan ?? prior.plan
                        current.credits = current.credits ?? prior.credits
                        current.resetCredits = current.resetCredits ?? prior.resetCredits
                        account = current
                    } else if account == nil {
                        account = old?.account
                    }
                    return ProfileUsage(
                        profile: profile,
                        quotas: QuotaMerge.merged(old?.quotas ?? [], with: quotas),
                        account: account
                    )
                }
            }
            var readings: [AgentAccountProfileID: ProfileUsage] = [:]
            for await reading in group {
                if let reading { readings[reading.id] = reading }
            }
            return profiles.compactMap { readings[$0.id] }
        }
    }

    public static func accountSource(
        for kind: AgentKind, environment: [String: String]
    ) -> (any AgentQuotaSource)? {
        switch kind {
        case .claudeCode: return ClaudeCodeQuotaSource(environment: environment)
        case .codex: return CodexQuotaSource(environment: environment)
        case .grok, .cursor, .openCode: return nil
        }
    }
}
