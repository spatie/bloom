import Foundation

/// Menu cards grouped by provider, sharing the provider's visibility and row layout without
/// contributing additional accounts to the starred metrics or default account severity.
public struct UsageProviderGroup: Identifiable, Sendable {
    public var provider: AgentKind
    public var defaultSection: UsageLayout.Section?
    public var profiles: [ProfileSection]
    public var id: AgentKind { provider }

    public struct ProfileSection: Identifiable, Sendable {
        public var usage: ProfileUsage
        public var section: UsageLayout.Section
        public var id: AgentAccountProfileID { usage.id }
    }

    public var hasOnDemand: Bool {
        defaultSection?.onDemand.isEmpty == false || profiles.contains { !$0.section.onDemand.isEmpty }
    }

    public func expansionTitle(isExpanded: Bool) -> String {
        "\(isExpanded ? "Hide" : "Show") \(provider.label) On Demand usage"
    }

    /// The custom menu item is disabled to avoid command highlighting, so AppKit needs its
    /// accessible summary explicitly. Use only the rows actually drawn by the saved layout.
    public func spoken(at now: Date, options: UsageDisplayOptions) -> String {
        var cards: [String] = []
        if let defaultSection {
            cards.append(reading(title: provider.label, plan: nil, section: defaultSection, at: now, options: options))
        }
        for profile in profiles {
            cards.append(reading(
                title: "\(provider.label), \(profile.usage.profile.name)", plan: profile.usage.account?.plan,
                section: profile.section, at: now, options: options
            ))
        }
        return cards.joined(separator: ". ")
    }

    private func reading(
        title: String, plan: String?, section: UsageLayout.Section, at now: Date, options: UsageDisplayOptions
    ) -> String {
        let rows = section.visible.map { metric in
            switch metric.content {
            case .meter(let quota):
                return UsageMeterReading.of(quota, isSession: metric.isSession, at: now, options: options)
                    .spoken(title: metric.title)
            case .value(let text, _, _): return "\(metric.title): \(text)"
            }
        }
        return ([title] + (plan.map { [$0] } ?? []) + rows).joined(separator: ". ")
    }

    public static func make(
        metrics: [AgentKind: [UsageMetric]],
        profiles: [ProfileUsage],
        layout: UsageLayout,
        at now: Date
    ) -> [UsageProviderGroup] {
        let defaults = Dictionary(uniqueKeysWithValues: layout.sections(for: metrics).map { ($0.provider, $0) })
        let profileSections: [ProfileSection] = profiles.compactMap { usage in
            let provider = usage.profile.kind
            guard layout.isEnabled(provider) else { return nil }
            let metrics = UsageCatalogue.metrics(
                quotas: usage.quotas,
                accounts: usage.account.map { [provider: $0] } ?? [:],
                at: now
            )
            if let section = layout.sections(for: metrics).first {
                return ProfileSection(usage: usage, section: section)
            }
            // A plan can be known before any window starts. Hidden metrics, however, must not
            // leave behind an otherwise empty card.
            guard metrics.isEmpty, usage.account?.plan != nil else { return nil }
            return ProfileSection(usage: usage, section: UsageLayout.Section(
                provider: provider, alwaysVisible: [], onDemand: [], isExpanded: false
            ))
        }
        let available = Set(defaults.keys).union(profileSections.map { $0.usage.profile.kind })
        return layout.orderedProviders(among: available).map { provider in
            UsageProviderGroup(
                provider: provider,
                defaultSection: defaults[provider],
                profiles: profileSections.filter { $0.usage.profile.kind == provider }
            )
        }
    }
}
