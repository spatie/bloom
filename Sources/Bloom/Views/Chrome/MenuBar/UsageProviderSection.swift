import SwiftUI
import BloomCore

/// One provider: its mark, name and plan over a card of metric rows, with the On Demand rows behind
/// a caret.
struct UsageProviderSectionView: View {
    let section: UsageLayout.Section
    let account: AgentAccount?
    let observedAt: Date?
    let isRefreshing: Bool
    let now: Date
    /// Off in a screenshot, which draws no spinner, no hover button and no menus.
    var isInteractive = true

    @Environment(UsagePanelModel.self) private var model
    @Environment(\.usageScale) private var scale
    @State private var isHovering = false
    @State private var isDropTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: scale.headerToCard) {
            header
                .padding(.horizontal, 8)
            card
        }
        // The whole section takes the drop, not just its header, because a card is a much easier
        // target than a row of text and the answer is the same wherever in it you let go.
        .overlay(alignment: .top) { insertionMark }
        .dropDestination(for: String.self) { items, _ -> Bool in
            return adopt(items)
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.12)) { isDropTarget = targeted && isInteractive }
        }
    }

    /// Where the dragged provider would land, drawn above the card the pointer is over.
    @ViewBuilder
    private var insertionMark: some View {
        if isDropTarget {
            Capsule()
                .fill(Color.accentColor)
                .frame(height: 2)
                .padding(.horizontal, 2)
                .offset(y: -6)
        }
    }

    /// Reorders the providers, which reorders the menu bar strip with them: both read
    /// `UsageLayout.providerOrder`.
    private func adopt(_ items: [String]) -> Bool {
        guard isInteractive, let raw = items.first,
              let dragged = AgentKind(rawValue: raw), dragged != provider
        else { return false }
        withAnimation(UsageMotion.spring) { model.update { $0.moveProvider(dragged, toward: provider) } }
        return true
    }

    private var provider: AgentKind { section.provider }

    private var header: some View {
        HStack(spacing: 5) {
            ProviderMarkView(provider: provider)
                .foregroundStyle(.secondary)
                .frame(width: scale.headerIcon, height: scale.headerIcon)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(provider.label)
                    .font(.system(size: scale.header, weight: .semibold))
                if let plan = account?.plan {
                    Text(plan)
                        .font(.system(size: scale.plan))
                        .foregroundStyle(.secondary)
                }
                if let age = staleAge {
                    Text("Outdated")
                        .font(.system(size: scale.plan))
                        .foregroundStyle(.tertiary)
                        .usageTooltip("Last updated \(age) ago")
                }
            }
            if isRefreshing, isInteractive {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Refreshing")
            }
            Spacer(minLength: 8)
            if isInteractive {
                Button {
                    model.copyScreenshot(of: section, account: account, now: now)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(isHovering ? 1 : 0)
                .usageTooltip("Copy Screenshot")
                .accessibilityLabel("Copy a screenshot of \(provider.label)")
            }
        }
        .padding(.leading, 2)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .draggable(provider.rawValue) {
            // What follows the pointer: the mark and the name, rather than a snapshot of the
            // whole header with its hover button and spinner in it.
            HStack(spacing: 5) {
                ProviderMarkView(provider: provider)
                    .foregroundStyle(.secondary)
                    .frame(width: scale.headerIcon, height: scale.headerIcon)
                Text(provider.label)
                    .font(.system(size: scale.header, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .contextMenu {
            if isInteractive {
                Button("Hide \(provider.label)") {
                    withAnimation(UsageMotion.spring) { model.update { $0.setEnabled(false, for: provider) } }
                }
                Divider()
                Button("Refresh \(provider.label)") { model.refresh() }
                Button("Customize\u{2026}") { model.navigate(to: .customize, provider: provider) }
                Divider()
                Button("Copy Screenshot") { model.copyScreenshot(of: section, account: account, now: now) }
            }
        }
    }

    /// How long ago the oldest figure on the card was read, once that is two polls or more.
    private var staleAge: String? {
        guard let observedAt, case .stale(let age) = QuotaFreshness.of(observedAt, at: now) else { return nil }
        return UsageFormat.compactDuration(age)
    }

    private var card: some View {
        VStack(spacing: 0) {
            rows(section.alwaysVisible)
            if !section.onDemand.isEmpty {
                caret
                if section.isExpanded {
                    rows(section.onDemand)
                }
            }
        }
        .padding(.vertical, scale.cardGutter)
        .usageCard()
    }

    private func rows(_ metrics: [UsageMetric]) -> some View {
        ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
            UsageMetricRow(
                metric: metric,
                now: now,
                isCondensed: index > 0 && metrics[index - 1].isText && metric.isText,
                isInteractive: isInteractive
            )
            .contextMenu {
                if isInteractive { rowMenu(metric) }
            }
        }
    }

    @ViewBuilder
    private func rowMenu(_ metric: UsageMetric) -> some View {
        Button("Hide") {
            withAnimation(UsageMotion.spring) { model.update { $0.setHidden(true, for: metric.id) } }
        }
        Button(model.layout.isPinned(metric.id) ? "Unstar" : "Star for Menu Bar") {
            model.togglePin(metric)
        }
        Divider()
        Button("Refresh \(provider.label)") { model.refresh() }
        Button("Customize\u{2026}") { model.navigate(to: .customize, provider: provider) }
    }

    private var caret: some View {
        Button {
            withAnimation(UsageMotion.spring) { model.update { $0.toggleExpanded(provider) } }
        } label: {
            Image(systemName: section.isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.isExpanded ? "Show less" : "Show more")
    }
}

extension UsageMetric {
    var isText: Bool {
        if case .value = content { return true }
        return false
    }
}
