import SwiftUI
import BloomCore

/// Rate limit news. Quiet on purpose: it is information, not a failure.
///
/// **It draws nothing at all unless the event carried a figure.** It used to default a missing
/// `utilization` to nought and print "0% of the five hour window used", which is a number Bloom
/// made up: the real payload has no such field until the account is near the wall. What the row
/// may say, and when there is anything to say, is `RateLimitNotice`, in the core, where it is
/// tested against the recorded event rather than argued about here.
struct RateLimitRowView: View {
    /// The stored `rate_limit_event`, whole. Read here rather than picked apart by the row,
    /// because deciding what it means is not a view's job.
    var payload: Data

    private var sentence: String? { RateLimitNotice.sentence(forRateLimitEvent: payload) }

    var body: some View {
        if let sentence {
            HStack(spacing: TranscriptLayout.glyphGap) {
                TranscriptGlyph(symbol: "gauge.with.dots.needle.33percent", tint: Palette.warning)

                Text("Rate limit")
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
                    .transcriptLabelColumn("Rate limit", font: Typo.label)

                Text(sentence)
                    .font(Typo.label)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .transcriptRowFrame()
        }
    }
}
