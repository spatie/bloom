import SwiftUI
import BloomCore

/// What the composer's context gauge says when it is opened.
///
/// The breakdown is the CLI's own count, asked of the running process as the popover opens.
/// Where nothing can answer (Codex, Grok, no process yet) the popover says so rather than guess.
struct ContextWindowDetail: View {
    var usage: ContextWindowUsage
    var loadBreakdown: (@MainActor () async -> ContextBreakdown?)?

    @State private var breakdown: ContextBreakdown?
    @State private var hasAsked = false

    private static let width: CGFloat = 252
    private static let barHeight: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingWide) {
            HStack(alignment: .firstTextBaseline) {
                Text("Context")
                    .font(Typo.labelEmphasis)

                Spacer()

                Text(ContextWindowUsage.percent(usage.fraction))
                    .font(Typo.label)
                    .monospacedDigit()
                    .foregroundStyle(usage.isCrowded ? Palette.warning : Palette.textSecondary)
            }

            ContextWindowBar(fraction: usage.fraction, isCrowded: usage.isCrowded)
                .frame(height: Self.barHeight)

            VStack(spacing: Metrics.spacingSmall) {
                row("In context", tokens: usage.used, tint: Palette.accent)
                ForEach(breakdown?.categories ?? [], id: \.name) { category in
                    detailRow(category)
                }
                row(
                    "Available",
                    tokens: usage.remaining,
                    tint: Palette.selected
                )
            }

            if hasAsked, breakdown == nil {
                Text("Detailed allocation is not reported by the agent.")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Metrics.gutter)
        .frame(width: Self.width)
        .task {
            breakdown = await loadBreakdown?()
            hasAsked = true
        }
    }

    /// Indented under "In context" by the width of its dot, so the names line up with its title.
    private func detailRow(_ category: ContextBreakdown.Category) -> some View {
        HStack(spacing: Metrics.spacing) {
            Text(category.name)

            Spacer(minLength: Metrics.spacing)

            Text(ContextWindowUsage.format(category.tokens))
                .monospacedDigit()
        }
        .font(Typo.caption)
        .foregroundStyle(Palette.textSecondary)
        .padding(.leading, Metrics.dot + Metrics.spacing)
    }

    private func row(_ title: String, tokens: Int, tint: Color) -> some View {
        HStack(spacing: Metrics.spacing) {
            Circle()
                .fill(tint)
                .frame(width: Metrics.dot, height: Metrics.dot)

            Text(title)

            Spacer(minLength: Metrics.spacing)

            Text(ContextWindowUsage.format(tokens))
                .monospacedDigit()
                .foregroundStyle(Palette.textSecondary)
        }
        .font(Typo.label)
    }
}
