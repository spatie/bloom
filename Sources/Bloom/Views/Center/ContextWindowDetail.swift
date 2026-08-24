import SwiftUI

/// What the composer's context gauge says when it is opened.
///
/// Three rows and a bar, and no more than that. Conductor's version of this popover breaks the
/// window down by system prompt, memory files, skills, MCP tools and custom agents. Claude Code's
/// stream reports none of those, so those rows would be numbers we made up, and a made-up number
/// next to a real one makes the real one unbelievable too.
struct ContextWindowDetail: View {
    var usage: ContextWindowUsage

    private static let width: CGFloat = 240
    private static let barHeight: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingWide) {
            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                Text("Context")
                    .font(Typo.title)

                Text("\(ContextWindowUsage.format(usage.used))/\(ContextWindowUsage.format(usage.limit))")
                    .font(Typo.body)
                    .monospacedDigit()
                    .foregroundStyle(Palette.textSecondary)
            }

            ContextWindowBar(fraction: usage.fraction, isCrowded: usage.isCrowded)
                .frame(height: Self.barHeight)

            VStack(spacing: Metrics.spacingSmall) {
                row("In context", tokens: usage.used, fraction: usage.fraction, tint: Palette.accent)
                row(
                    "Free space",
                    tokens: usage.remaining,
                    fraction: 1 - usage.fraction,
                    tint: Palette.selected
                )
            }

            // Said once, quietly, rather than left for the reader to wonder about. Somebody who has
            // seen Conductor's popover will come here looking for the categories.
            Text("The agent reports the total only, never what fills it.")
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Metrics.gutter)
        .frame(width: Self.width)
    }

    private func row(_ title: String, tokens: Int, fraction: Double, tint: Color) -> some View {
        HStack(spacing: Metrics.spacing) {
            Circle()
                .fill(tint)
                .frame(width: Metrics.dot, height: Metrics.dot)

            Text(title)

            Spacer(minLength: Metrics.spacing)

            Text(ContextWindowUsage.format(tokens))
                .monospacedDigit()
                .foregroundStyle(Palette.textSecondary)

            Text(ContextWindowUsage.percent(fraction))
                .monospacedDigit()
                .foregroundStyle(Palette.textTertiary)
                .frame(width: 38, alignment: .trailing)
        }
        .font(Typo.label)
    }
}
