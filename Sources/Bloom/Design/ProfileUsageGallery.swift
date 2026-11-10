import AppKit
import SwiftUI
import BloomCore

/// The real menu block with fixed account readings, so no credentials or shared dev installation
/// are needed to photograph its changed states. Run with an isolated BLOOM_DB_PATH:
///
///     .build/debug/Bloom --snapshot /tmp/usage-shots --usage-accounts-only
@MainActor
enum ProfileUsageGallery {
    private static let now = Date(timeIntervalSince1970: 1_794_300_000)

    private static func quotas(_ provider: AgentKind, session: Double, weekly: Double) -> [AgentQuota] {
        let windows: [(QuotaWindow, Double)] = provider == .claudeCode
            ? [(.named("five_hour"), session), (.named("seven_day"), weekly),
               (QuotaWindow(key: "seven_day_model_opus", label: "Week (Opus)", duration: 604_800), 0.43)]
            : [(.lasting(18_000, key: "primary"), session), (.lasting(604_800, key: "secondary"), weekly),
               (QuotaWindow(key: "codex_bengalfox.secondary", label: "Week (Spark)", duration: 604_800), 0.17)]
        return windows.map { window, fraction in
            AgentQuota(
                provider: provider, window: window, measure: .fraction(fraction),
                resetsAt: now + (window.duration ?? 604_800) * 0.6, observedAt: now
            )
        }
    }

    static func render(to directory: String) {
        let suite = "be.spatie.bloom.usage-gallery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = UsageMenuModel(defaults: defaults)
        let claude = quotas(.claudeCode, session: 0.22, weekly: 0.38)
        let codex = quotas(.codex, session: 0.14, weekly: 0.29)
        let accounts: [AgentKind: AgentAccount] = [
            .claudeCode: AgentAccount(provider: .claudeCode, plan: "Max", observedAt: now),
            .codex: AgentAccount(provider: .codex, plan: "Pro 20x", observedAt: now),
        ]
        let profiles = [
            ProfileUsage(
                profile: AgentAccountProfile(kind: .claudeCode, name: "Work team"),
                quotas: quotas(.claudeCode, session: 0.61, weekly: 0.72),
                account: AgentAccount(provider: .claudeCode, plan: "Team", observedAt: now)
            ),
            ProfileUsage(
                profile: AgentAccountProfile(kind: .claudeCode, name: "Personal"),
                quotas: quotas(.claudeCode, session: 0.08, weekly: 0.11),
                account: AgentAccount(provider: .claudeCode, plan: "Pro", observedAt: now)
            ),
            ProfileUsage(
                profile: AgentAccountProfile(kind: .codex, name: "Company"),
                quotas: quotas(.codex, session: 0.44, weekly: 0.53),
                account: AgentAccount(provider: .codex, plan: "Business Premium", credits: .init(balance: 120), observedAt: now)
            ),
        ]
        let metrics = UsageCatalogue.metrics(quotas: claude + codex, accounts: accounts, at: now)
        for appearanceName in ["light", "dark"] {
            let appearance = NSAppearance(named: appearanceName == "dark" ? .darkAqua : .aqua)!
            // This route skips bootstrap, so it must create the process's application before
            // resolving AppKit colours. With NSApp still nil the dark page had white ink on white.
            NSApplication.shared.appearance = appearance
            model.update { $0 = UsageLayout() }
            capture("before", profiles: [], metrics: metrics, accounts: accounts)
            capture("additional", profiles: profiles, metrics: metrics, accounts: accounts)
            model.update {
                $0.providerOrder = [.codex, .claudeCode]
                $0.hidden.insert(UsageMetricID("claudeCode/seven_day_model_opus"))
                $0.metricOrder = [UsageMetricID("claudeCode/seven_day"), UsageMetricID("claudeCode/five_hour")]
                $0.placements[UsageMetricID("claudeCode/five_hour")] = .onDemand
            }
            capture("layout-collapsed", profiles: profiles, metrics: metrics, accounts: accounts)
            model.update { $0.expandedProviders = [.claudeCode, .codex] }
            capture("layout-expanded", profiles: profiles, metrics: metrics, accounts: accounts)
            model.update { $0 = UsageLayout() }
            capture("without-default", profiles: profiles, metrics: [:], accounts: [:])
            model.update { $0.expandedProviders = [.claudeCode, .codex] }
            capture("without-default-expanded", profiles: profiles, metrics: [:], accounts: [:])
            model.update { $0.disabledProviders = [.codex] }
            capture("provider-disabled", profiles: profiles, metrics: metrics, accounts: accounts)
            model.update { $0 = UsageLayout() }
            let planOnly = ProfileUsage(
                profile: AgentAccountProfile(kind: .codex, name: "New login"), quotas: [],
                account: AgentAccount(provider: .codex, plan: "Pro 5x", observedAt: now)
            )
            capture("plan-only", profiles: [planOnly], metrics: [:], accounts: [:])

            func capture(
                _ state: String, profiles: [ProfileUsage],
                metrics: [AgentKind: [UsageMetric]], accounts: [AgentKind: AgentAccount]
            ) {
                appearance.performAsCurrentDrawingAppearance {
                    let view = UsageMenuBlock(
                        model: model, metrics: metrics, accounts: accounts, now: now,
                        profiles: profiles, canReorder: false
                    )
                    .padding(.vertical, 12)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, appearanceName == "dark" ? .dark : .light)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 2
                    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                          let bitmap = NSBitmapImageRep(data: tiff),
                          let png = bitmap.representation(using: .png, properties: [:]) else { return }
                    let path = "\(directory)/usage-accounts-\(state)-\(appearanceName).png"
                    do {
                        try png.write(to: URL(fileURLWithPath: path))
                        print(path)
                    } catch {
                        FileHandle.standardError.write(Data("Could not write \(path): \(error)\n".utf8))
                    }
                }
            }
        }
    }
}
