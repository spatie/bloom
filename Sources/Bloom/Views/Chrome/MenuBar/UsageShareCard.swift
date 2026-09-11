import SwiftUI
import BloomCore

/// One provider's card as it is copied to the pasteboard: the mark, the plan, the rows the panel is
/// showing, and a line saying where it came from. No spinner, no hover button, no tooltips.
struct UsageShareCard: View {
    let section: UsageLayout.Section
    let account: AgentAccount?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProviderMarkView(provider: section.provider)
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                Text(section.provider.label)
                    .font(.system(size: 15, weight: .semibold))
                if let plan = account?.plan {
                    Text(plan)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 0) {
                ForEach(section.visible) { metric in
                    UsageMetricRow(metric: metric, now: now, isInteractive: false)
                }
            }
            .padding(.vertical, 5)
            .usageCard()
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                Text("Agent limits, from Bloom")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
        .background(UsageInk.tray)
    }
}
