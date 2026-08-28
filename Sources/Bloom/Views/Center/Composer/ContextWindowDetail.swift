import SwiftUI

/// What the composer's context gauge says when it is opened.
///
/// Three rows and a bar, and no more than that. Conductor's version of this popover breaks the
/// window down by system prompt, memory files, skills, MCP tools and custom agents. Claude Code's
/// stream reports none of those, so those rows would be numbers we made up, and a made-up number
/// next to a real one makes the real one unbelievable too.
struct ContextWindowDetail: View {
    var usage: ContextWindowUsage

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
                row(
                    "Available",
                    tokens: usage.remaining,
                    tint: Palette.selected
                )
            }

            Text("Detailed allocation is not reported by the agent.")
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Metrics.gutter)
        .frame(width: Self.width)
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
