import AppKit
import SwiftUI
import BloomCore

/// What the menu bar item shows, and what somebody arranged in Settings ▸ Menu Bar.
///
/// One instance for the life of the process, shared by the menu and the status item, because the
/// item draws the starred metrics out of the same layout the Settings pane edits.
@MainActor
@Observable
final class UsageMenuModel {
    static let shared = UsageMenuModel()

    private(set) var layout: UsageLayout

    /// Whether the item carries figures at all. Off, and it is Bloom's mark alone.
    var showsUsage: Bool {
        didSet { defaults.set(showsUsage, forKey: UsagePreferenceKey.showsUsage) }
    }
    /// Whether a cup is drawn while the Mac is being kept awake.
    var showsCup: Bool {
        didSet { defaults.set(showsCup, forKey: UsagePreferenceKey.showsCup) }
    }
    var meterStyle: UsageMeterStyle {
        didSet { defaults.set(meterStyle.rawValue, forKey: UsagePreferenceKey.meterStyle) }
    }
    var iconStyle: MenuBarIconStyle {
        didSet { defaults.set(iconStyle.rawValue, forKey: UsagePreferenceKey.iconStyle) }
    }

    @ObservationIgnored private let defaults: UserDefaults
    /// Set by the status item: ask both providers again now.
    @ObservationIgnored var refresh: () -> Void = {}

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        layout = UsageLayout.load(from: defaults)
        showsUsage = defaults.object(forKey: UsagePreferenceKey.showsUsage) as? Bool ?? true
        showsCup = defaults.object(forKey: UsagePreferenceKey.showsCup) as? Bool ?? true
        meterStyle = defaults.string(forKey: UsagePreferenceKey.meterStyle)
            .flatMap(UsageMeterStyle.init(rawValue:)) ?? .left
        iconStyle = defaults.string(forKey: UsagePreferenceKey.iconStyle)
            .flatMap(MenuBarIconStyle.init(rawValue:)) ?? .text
    }

    var options: UsageDisplayOptions { UsageDisplayOptions(meterStyle: meterStyle) }

    // MARK: - Layout

    func update(_ change: (inout UsageLayout) -> Void) {
        var copy = layout
        change(&copy)
        guard copy != layout else { return }
        layout = copy
        layout.save(to: defaults)
    }

    func adopt(_ metrics: [AgentKind: [UsageMetric]]) {
        update { $0.adopt(metrics) }
    }

    /// Moves a provider to where another one sits. The menu and the menu bar both read this order.
    func move(_ provider: AgentKind, toward target: AgentKind) {
        update { $0.moveProvider(provider, toward: target) }
    }

    @discardableResult
    func togglePin(_ metric: UsageMetric) -> UsageLayout.PinOutcome {
        var outcome = UsageLayout.PinOutcome.unpinned
        update { outcome = $0.togglePin(metric) }
        return outcome
    }

    /// Everything the two providers have reported, adopted so a metric seen for the first time
    /// arrives with its default star.
    func metrics(quotas: [AgentQuota], accounts: [AgentKind: AgentAccount], at now: Date = Date()) -> [AgentKind: [UsageMetric]] {
        let metrics = UsageCatalogue.metrics(quotas: quotas, accounts: accounts, at: now)
        adopt(metrics)
        return metrics
    }
}
