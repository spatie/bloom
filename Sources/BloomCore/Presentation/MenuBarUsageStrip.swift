import Foundation

/// What the menu bar item draws for the starred metrics: each provider's mark with one or two
/// figures stacked beside it, or up to four bars in one square.
///
/// **A metric with no figure is left out rather than drawn as a placeholder**, and a provider whose
/// every star lacks a figure drops out entirely, so the strip never carries a mark with nothing
/// beside it. When nothing at all is left the item falls back to Bloom's own mark.
public struct MenuBarUsageStrip: Sendable, Hashable {
    public struct Group: Sendable, Hashable, Identifiable {
        public var provider: AgentKind
        /// One or two figures, top first. No labels: two numbers stacked is all the height the
        /// menu bar has, and the order is the one the panel lists them in.
        public var values: [String]
        public var id: AgentKind { provider }
    }

    public static let maximumBars = 4

    public var groups: [Group]
    /// The first four starred meters' fills, across providers, for the bars style.
    public var bars: [Double]
    /// "Claude Code Session 41% left, Weekly 12% left; Codex Weekly 90% left".
    public var spoken: String

    public var isEmpty: Bool { groups.isEmpty }

    public init(groups: [Group] = [], bars: [Double] = [], spoken: String = "") {
        self.groups = groups
        self.bars = bars
        self.spoken = spoken
    }

    public static func make(
        layout: UsageLayout,
        metrics: [AgentKind: [UsageMetric]],
        at now: Date = Date(),
        options: UsageDisplayOptions = UsageDisplayOptions()
    ) -> MenuBarUsageStrip {
        var groups: [Group] = []
        var bars: [Double] = []
        var spoken: [String] = []

        for (provider, starred) in layout.pinnedMetrics(in: metrics) {
            var values: [String] = []
            var phrases: [String] = []
            for metric in starred {
                switch metric.content {
                case .meter(let quota):
                    let reading = UsageMeterReading.of(quota, isSession: metric.isSession, at: now, options: options)
                    guard let value = reading.menuBarValue else { continue }
                    values.append(value)
                    phrases.append("\(metric.title) \(reading.headline)")
                    if bars.count < maximumBars { bars.append(reading.fill) }
                case .value(let text, let tray, _):
                    guard let tray else { continue }
                    values.append(tray)
                    phrases.append("\(metric.title) \(text)")
                }
            }
            guard !values.isEmpty else { continue }
            groups.append(Group(provider: provider, values: values))
            spoken.append("\(provider.label) \(phrases.joined(separator: ", "))")
        }
        return MenuBarUsageStrip(groups: groups, bars: bars, spoken: spoken.joined(separator: "; "))
    }
}
