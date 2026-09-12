import SwiftUI
import BloomCore

/// Customize, first level: every provider, switched on or off, in the order the panel draws them.
/// Drag a row to reorder, click it for its metrics.
struct UsageCustomizeListView: View {
    let app: AppModel
    @Environment(UsagePanelModel.self) private var model
    @Environment(\.usageScale) private var scale

    var body: some View {
        let metrics = UsageCatalogue.metrics(quotas: app.quotas, accounts: app.accounts)
        VStack(alignment: .leading, spacing: scale.section) {
            VStack(spacing: 0) {
                ForEach(model.layout.orderedProviders(), id: \.self) { provider in
                    row(provider, count: metrics[provider]?.count ?? 0)
                }
            }
            .padding(.vertical, scale.cardGutter)
            .usageCard()

            VStack(spacing: 0) {
                UsageLinkRow(symbol: "gearshape", title: "Settings", detail: "Appearance, usage display and more") {
                    model.navigate(to: .settings)
                }
            }
            .usageCard()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func row(_ provider: AgentKind, count: Int) -> some View {
        let isEnabled = model.layout.isEnabled(provider)
        return HStack(spacing: 10) {
            UsageGrip()
            ProviderMarkView(provider: provider)
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.label)
                    .font(.system(size: scale.header, weight: .semibold))
                Text(count == 0 ? "Nothing reported yet" : Counted.of(count, "metric"))
                    .font(.system(size: scale.plan))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Toggle(provider.label, isOn: Binding(
                get: { model.layout.isEnabled(provider) },
                set: { value in withAnimation(UsageMotion.spring) { model.update { $0.setEnabled(value, for: provider) } } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, scale.controlRow)
        .contentShape(Rectangle())
        .opacity(isEnabled ? 1 : 0.55)
        .onTapGesture { model.navigate(to: .customize, provider: provider) }
        .draggable(provider.rawValue)
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let dragged = AgentKind(rawValue: raw), dragged != provider else { return false }
            withAnimation(UsageMotion.spring) { model.update { $0.moveProvider(dragged, toward: provider) } }
            return true
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// Customize, second level: one provider's metrics, split into the ones the card always shows and
/// the ones behind its caret. Drag a row between the two sections, star it for the menu bar, or
/// switch it off.
struct UsageCustomizeProviderView: View {
    let app: AppModel
    let provider: AgentKind
    @Environment(UsagePanelModel.self) private var model
    @Environment(\.usageScale) private var scale

    var body: some View {
        let all = model.layout.orderedMetrics(
            UsageCatalogue.metrics(quotas: app.quotas, accounts: app.accounts)[provider] ?? []
        )
        VStack(alignment: .leading, spacing: scale.section) {
            if all.isEmpty {
                Text("\(provider.label) has not reported any limits yet. Its metrics appear here once it has.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .usageCard()
            } else {
                section("Always Visible", placement: .alwaysVisible, all: all)
                section("On Demand", placement: .onDemand, all: all)
                Text("Starred metrics show in the menu bar, up to two per provider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func section(_ title: String, placement: UsageLayout.Placement, all: [UsageMetric]) -> some View {
        let metrics = all.filter { model.layout.placement(of: $0.id) == placement }
        return VStack(alignment: .leading, spacing: scale.headerToCard) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            Group {
                if metrics.isEmpty {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .foregroundStyle(.tertiary)
                        .frame(height: 30)
                        .overlay {
                            Text("Drag metrics here")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(8)
                } else {
                    VStack(spacing: 0) {
                        ForEach(metrics) { metric in
                            row(metric, placement: placement, all: all)
                        }
                    }
                    .padding(.vertical, scale.cardGutter)
                }
            }
            .usageCard()
            .dropDestination(for: String.self) { items, _ -> Bool in
                return move(items, before: nil, into: placement, all: all)
            }
        }
    }

    private func row(_ metric: UsageMetric, placement: UsageLayout.Placement, all: [UsageMetric]) -> some View {
        let isHidden = model.layout.isHidden(metric.id)
        let isPinned = model.layout.isPinned(metric.id)
        return HStack(spacing: 10) {
            UsageGrip()
            Text(metric.title)
                .font(.system(size: scale.label))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                model.togglePin(metric)
            } label: {
                Image(systemName: isPinned ? "star.fill" : "star")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isPinned ? Color.accentColor : Color.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .usageTooltip(isPinned ? "Remove from menu bar" : "Star for menu bar")
            .accessibilityLabel(isPinned ? "Unstar \(metric.title)" : "Star \(metric.title) for the menu bar")
            Toggle(metric.title, isOn: Binding(
                get: { !model.layout.isHidden(metric.id) },
                set: { visible in model.update { $0.setHidden(!visible, for: metric.id) } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, scale.controlRow)
        .contentShape(Rectangle())
        .opacity(isHidden ? 0.55 : 1)
        .draggable(metric.id.rawValue)
        .dropDestination(for: String.self) { items, _ -> Bool in
            return move(items, before: metric.id, into: placement, all: all)
        }
    }

    private func move(_ items: [String], before target: UsageMetricID?, into placement: UsageLayout.Placement, all: [UsageMetric]) -> Bool {
        guard let raw = items.first else { return false }
        let id = UsageMetricID(raw)
        guard id != target, all.contains(where: { $0.id == id }) else { return false }
        withAnimation(UsageMotion.spring) {
            model.update { $0.move(id, before: target, into: placement, among: all) }
        }
        return true
    }
}

/// The handle a draggable row is picked up by.
struct UsageGrip: View {
    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .frame(width: 16, height: 22)
            .accessibilityHidden(true)
    }
}
