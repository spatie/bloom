import Foundation
import Testing
@testable import BloomCore

private let usageNow = Date(timeIntervalSince1970: 1_794_300_000)

private struct ProfileQuotaSource: AgentQuotaSource {
    static let provider = AgentKind.codex
    var payload: Data?
    var readPayload: (@Sendable () async -> Data?)?
    func read() async -> Data? {
        if let readPayload { return await readPayload() }
        return payload
    }
}

private func usageQuota(_ kind: AgentKind, _ key: String, _ fraction: Double) -> AgentQuota {
    AgentQuota(
        provider: kind, window: .named(key), measure: .fraction(fraction),
        resetsAt: usageNow + 3_600, observedAt: usageNow
    )
}

@Suite("Additional account usage")
struct ProfileUsageTests {
    @Test func isolatesHomesAndClearsDefaultCredentials() async {
        let profiles = [
            AgentAccountProfile(kind: .claudeCode, name: "Team"),
            AgentAccountProfile(kind: .codex, name: "Personal"),
            AgentAccountProfile(kind: .grok, name: "Other"),
        ]
        let report = await AgentQuotaSources.report(
            profiles: profiles, home: { "/profiles/\($0.id.rawValue)" },
            environment: [
                "ANTHROPIC_API_KEY": "default", "CLAUDE_CODE_OAUTH_TOKEN": "default",
                "OPENAI_API_KEY": "default", "CODEX_API_KEY": "default", "PATH": "/bin",
            ],
            at: usageNow,
            makeSource: { kind, environment in
                #expect(environment["PATH"] == "/bin")
                switch kind {
                case .claudeCode:
                    #expect(environment["CLAUDE_CONFIG_DIR"] == "/profiles/\(profiles[0].id.rawValue)")
                    #expect(environment["ANTHROPIC_API_KEY"] == nil)
                    #expect(environment["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
                    return ProfileQuotaSource(payload: Data("""
                    {"rate_limits_available":true,"subscription_type":"team","rate_limits":{"five_hour":{"utilization":26}}}
                    """.utf8))
                case .codex:
                    #expect(environment["CODEX_HOME"] == "/profiles/\(profiles[1].id.rawValue)")
                    #expect(environment["OPENAI_API_KEY"] == nil)
                    #expect(environment["CODEX_API_KEY"] == nil)
                    return ProfileQuotaSource(payload: Data("""
                    {"rateLimits":{"planType":"pro","primary":{"usedPercent":14,"windowDurationMins":300}}}
                    """.utf8))
                default: return nil
                }
            }
        )
        #expect(report.map(\.profile) == Array(profiles.prefix(2)))
        #expect(report.map { $0.account?.plan } == ["Team", "Pro 20x"])
        #expect(report.map { $0.quotas.first?.fraction } == [0.26, 0.14])
    }

    @Test func mergesOnlyWithinTheSameProfileAndSkipsSignedOutHomes() async throws {
        let first = AgentAccountProfile(kind: .codex, name: "First")
        let second = AgentAccountProfile(kind: .codex, name: "Second")
        let signedOut = AgentAccountProfile(kind: .codex, name: "Signed out")
        let unavailable = AgentAccountProfile(kind: .codex, name: "Unavailable")
        let planOnly = AgentAccountProfile(kind: .codex, name: "Plan only")
        let old = [first, second, signedOut, unavailable].enumerated().map { index, profile in
            ProfileUsage(
                profile: profile,
                quotas: [AgentQuota(
                    provider: .codex, window: .lasting(18_000, key: "primary"),
                    measure: .fraction(Double(index + 1) / 10), resetsAt: usageNow + 3_600 + Double(index) * 300,
                    observedAt: usageNow - 60
                )],
                account: AgentAccount(provider: .codex, plan: "Pro 5x", observedAt: usageNow - 60)
            )
        }
        let report = await AgentQuotaSources.report(
            profiles: [second, signedOut, first, unavailable, planOnly], known: old,
            home: { $0.name }, at: usageNow,
            makeSource: { _, environment in
                switch environment["CODEX_HOME"] {
                case "Signed out": return ProfileQuotaSource(payload: Data("{\"rateLimits\":{}}".utf8))
                case "Unavailable": return ProfileQuotaSource(payload: nil)
                case "Plan only": return ProfileQuotaSource(payload: Data("{\"rateLimits\":{\"planType\":\"pro\"}}".utf8))
                default:
                    return ProfileQuotaSource(payload: Data("{\"rateLimits\":{\"primary\":{\"usedPercent\":37}}}".utf8))
                }
            }
        )
        #expect(report.map(\.profile) == [second, first, unavailable, planOnly])
        let merged = try #require(report.first)
        #expect(merged.quotas.first?.window.duration == 18_000)
        #expect(merged.quotas.first?.resetsAt == usageNow + 3_900)
        #expect(report[1].quotas.first?.resetsAt == usageNow + 3_600)
        #expect(merged.quotas.first?.fraction == 0.37)
        #expect(merged.account?.plan == "Pro 5x")
        #expect(report[2].quotas.first?.fraction == 0.4)
        #expect(report[3].quotas.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func asksAllProfilesConcurrentlyAndReturnsSettingsOrder() async {
        let gate = ProfileReadGate()
        let profiles = [
            AgentAccountProfile(kind: .codex, name: "Slow"),
            AgentAccountProfile(kind: .codex, name: "Fast"),
        ]
        let readings = await AgentQuotaSources.report(
            profiles: profiles, home: { $0.name }, at: usageNow,
            makeSource: { _, environment in
                let name = environment["CODEX_HOME"]!
                return ProfileQuotaSource(readPayload: { await gate.read(name) })
            }
        )
        #expect(readings.map(\.profile) == profiles)
    }
}

private actor ProfileReadGate {
    private var pending: [AsyncStream<Void>.Continuation] = []

    func read(_ name: String) async -> Data? {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        pending.append(continuation)
        // Both reads must start before either can finish. AsyncStream also ends on cancellation,
        // so the suite's time limit can stop a regressed serial implementation.
        if pending.count == 2 {
            for continuation in pending.reversed() { continuation.finish() }
        }
        for await _ in stream {}
        return Data("{\"rateLimits\":{\"planType\":\"pro\"}}".utf8)
    }
}

@Suite("Additional account menu layout")
struct ProfileUsageLayoutTests {
    private let profiles = [
        ProfileUsage(profile: AgentAccountProfile(kind: .claudeCode, name: "Team"), quotas: [
            usageQuota(.claudeCode, "five_hour", 0.1), usageQuota(.claudeCode, "seven_day", 0.2),
            usageQuota(.claudeCode, "seven_day_sonnet", 0.3),
        ]),
        ProfileUsage(profile: AgentAccountProfile(kind: .codex, name: "Company"), quotas: [
            usageQuota(.codex, "primary", 0.4),
        ]),
        ProfileUsage(profile: AgentAccountProfile(kind: .claudeCode, name: "Personal"), quotas: [
            usageQuota(.claudeCode, "five_hour", 0.5), usageQuota(.claudeCode, "seven_day", 0.6),
        ]),
    ]

    @Test func groupsInProviderAndSettingsOrderWithoutADefaultCard() {
        let layout = UsageLayout(providerOrder: [.codex, .claudeCode])
        let groups = UsageProviderGroup.make(metrics: [:], profiles: profiles, layout: layout, at: usageNow)
        #expect(groups.map(\.provider) == [.codex, .claudeCode])
        #expect(groups.allSatisfy { $0.defaultSection == nil })
        #expect(groups[1].profiles.map { $0.usage.profile.name } == ["Team", "Personal"])
        #expect(groups[1].profiles.first?.section.visible.map(\.title) == ["Session", "Weekly"])
    }

    @Test func inheritsRowOrderHiddenRowsExpansionAndDisabledProviders() throws {
        var layout = UsageLayout(
            disabledProviders: [.codex],
            metricOrder: [UsageMetricID("claudeCode/seven_day"), UsageMetricID("claudeCode/five_hour")],
            placements: [UsageMetricID("claudeCode/five_hour"): .onDemand],
            hidden: [UsageMetricID("claudeCode/seven_day_sonnet")]
        )
        let collapsed = UsageProviderGroup.make(metrics: [:], profiles: profiles, layout: layout, at: usageNow)
        #expect(collapsed.map(\.provider) == [.claudeCode])
        #expect(collapsed[0].profiles.allSatisfy { $0.section.visible.map(\.title) == ["Weekly"] })
        layout.expandedProviders = [.claudeCode]
        let expanded = UsageProviderGroup.make(metrics: [:], profiles: profiles, layout: layout, at: usageNow)
        #expect(expanded[0].profiles.allSatisfy { $0.section.visible.map(\.title) == ["Weekly", "Session"] })
        layout.hidden.insert(UsageMetricID("claudeCode/five_hour"))
        layout.hidden.insert(UsageMetricID("claudeCode/seven_day"))
        let hidden = UsageProviderGroup.make(metrics: [:], profiles: profiles, layout: layout, at: usageNow)
        #expect(hidden.isEmpty)
    }

    @Test func exposesProfileOnlyOnDemandRowsAndIncludesThemInTheSpokenSummary() throws {
        var layout = UsageLayout()
        let group = try #require(UsageProviderGroup.make(
            metrics: [:], profiles: [profiles[0]], layout: layout, at: usageNow
        ).first)
        #expect(group.hasOnDemand)
        #expect(group.expansionTitle(isExpanded: false) == "Show Claude Code On Demand usage")
        #expect(!group.spoken(at: usageNow, options: UsageDisplayOptions()).contains("Sonnet"))
        layout.toggleExpanded(.claudeCode)
        let expanded = try #require(UsageProviderGroup.make(
            metrics: [:], profiles: [profiles[0]], layout: layout, at: usageNow
        ).first)
        let spoken = expanded.spoken(at: usageNow, options: UsageDisplayOptions())
        #expect(spoken.contains("Team"))
        #expect(spoken.contains("Session"))
        #expect(spoken.contains("Weekly"))
        #expect(spoken.contains("Sonnet"))
    }

    @Test func keepsAPlanOnlyProfileAndPromotesAllOnDemandRows() {
        let planOnly = ProfileUsage(
            profile: AgentAccountProfile(kind: .codex, name: "New login"), quotas: [],
            account: AgentAccount(provider: .codex, plan: "Pro 20x", observedAt: usageNow)
        )
        let layout = UsageLayout(placements: [
            UsageMetricID("claudeCode/five_hour"): .onDemand,
            UsageMetricID("claudeCode/seven_day"): .onDemand,
        ])
        let groups = UsageProviderGroup.make(metrics: [:], profiles: [profiles[2], planOnly], layout: layout, at: usageNow)
        #expect(groups[0].profiles[0].section.visible.map(\.title) == ["Session", "Weekly"])
        #expect(groups[1].profiles[0].usage.account?.plan == "Pro 20x")
        #expect(groups[1].profiles[0].section.visible.isEmpty)
    }
}
