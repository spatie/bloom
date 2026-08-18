import SwiftUI

/// Rate limit news. Quiet on purpose: it is information, not a failure.
struct RateLimitRowView: View {
    /// A fraction, not a percentage: 0.42 means 42% of the window is gone.
    var utilization: Double
    /// The raw window name as the CLI writes it, such as `five_hour`.
    var window: String

    private var used: String {
        utilization.formatted(.percent.precision(.fractionLength(0)))
    }

    private var readableWindow: String {
        window.replacing("_", with: " ")
    }

    var body: some View {
        HStack(spacing: TranscriptLayout.glyphGap) {
            TranscriptGlyph(symbol: "gauge.with.dots.needle.33percent", tint: Palette.warning)

            Text("Rate limit")
                .font(Typo.labelEmphasis)
                .foregroundStyle(Palette.textSecondary)
                .frame(width: TranscriptLayout.labelWidth, alignment: .leading)

            Text(window.isEmpty
                ? "\(used) used"
                : "\(used) of the \(readableWindow) window used")
                .font(Typo.label)
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .transcriptRowFrame()
    }
}
