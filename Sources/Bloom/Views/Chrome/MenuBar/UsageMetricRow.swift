import SwiftUI
import BloomCore

/// One metric: a meter row for a window, a line of text for a balance.
///
/// Every word and every colour on it is decided by `UsageMeterReading` in the core; this is the
/// ink and the geometry. Clicking the headline flips every meter between Left and Used, and
/// clicking a reset time flips between a countdown and a clock time, both as OpenUsage does.
struct UsageMetricRow: View {
    let metric: UsageMetric
    let now: Date
    /// A text row directly under another text row sits closer to it, so a run of balances reads as
    /// one block.
    var isCondensed = false
    var isInteractive = true

    @Environment(UsagePanelModel.self) private var model
    @Environment(\.usageScale) private var scale

    var body: some View {
        switch metric.content {
        case .meter(let quota):
            meter(UsageMeterReading.of(quota, isSession: metric.isSession, at: now, options: model.options))
        case .value(let text, _, let tooltip):
            value(text, tooltip: tooltip)
        }
    }

    private func meter(_ reading: UsageMeterReading) -> some View {
        VStack(alignment: .leading, spacing: scale.rowInner) {
            HStack(spacing: 6) {
                Text(metric.title)
                    .font(.system(size: scale.label, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let status = reading.status {
                    statusView(status)
                }
            }

            UsageMeterBar(reading: reading, height: scale.meterHeight)
                .usageTooltip(reading.paceTooltip)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    model.meterStyle = model.meterStyle.toggled
                } label: {
                    Text(reading.headline)
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText())
                }
                .buttonStyle(.plain)
                .usageTooltip(reading.headlineAlternate)

                Spacer(minLength: 8)

                if let alternate = reading.trailingAlternate {
                    Button {
                        model.resetDisplay = model.resetDisplay.toggled
                    } label: {
                        Text(reading.trailing)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .usageTooltip(alternate)
                } else {
                    Text(reading.trailing)
                        .foregroundStyle(.secondary)
                        .usageTooltip(reading.trailingTooltip)
                }
            }
            .font(.system(size: scale.supporting))
            .monospacedDigit()
            .lineLimit(1)
        }
        .padding(.vertical, scale.barRowPadding)
        .padding(.horizontal, 14)
        .allowsHitTesting(isInteractive)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reading.spoken(title: metric.title))
        .accessibilityAction(named: "Show \(model.meterStyle.toggled.title.lowercased())") {
            model.meterStyle = model.meterStyle.toggled
        }
    }

    private func statusView(_ status: UsageMeterReading.Status) -> some View {
        HStack(spacing: 4) {
            if status.showsFlame {
                Image(systemName: "flame.fill")
                    .font(.system(size: scale.supporting - 1))
                    .foregroundStyle(UsageInk.critical)
            }
            if let text = status.text {
                if status.isDeadline {
                    Button {
                        model.resetDisplay = model.resetDisplay.toggled
                    } label: {
                        Text(text)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(text)
                }
            }
        }
        .font(.system(size: scale.supporting))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .usageTooltip(status.tooltip)
    }

    private func value(_ text: String, tooltip: String?) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(metric.title)
                .font(.system(size: scale.supporting, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 12)
            Text(text)
                .font(.system(size: scale.supporting))
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.top, isCondensed ? scale.condensedTop : scale.textRowPadding)
        .padding(.bottom, scale.textRowPadding)
        .padding(.horizontal, 14)
        .usageTooltip(tooltip)
        .accessibilityElement(children: .combine)
    }
}

/// The capsule meter, with the tick where usage would be if it were perfectly even across the
/// window. The tick is drawn only when the pace is worth a look, or always when the setting asks.
struct UsageMeterBar: View {
    let reading: UsageMeterReading
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                if reading.tone != .empty, reading.fill > 0 {
                    Capsule()
                        .fill(UsageInk.tone(reading.tone))
                        // Never thinner than it is tall, so the smallest honest fill is a dot
                        // rather than a sliver nobody can see.
                        .frame(width: min(width, max(height, width * reading.fill)))
                }
            }
            .overlay(alignment: .leading) {
                if let tick = reading.paceTick {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: 2, height: height + 4)
                        .offset(x: min(max(width * tick - 1, 0), max(0, width - 2)))
                }
            }
        }
        .frame(height: height)
        .animation(UsageMotion.spring, value: reading.fill)
        .accessibilityHidden(true)
    }
}
