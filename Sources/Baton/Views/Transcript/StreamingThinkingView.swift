import SwiftUI

/// Reasoning as it arrives.
///
/// Streaming thinking is a scroll of consciousness. Only the tail is interesting, and only the tail
/// is cheap: laying out a hundred kilobytes of italic text on every delta is not something a
/// transcript can afford.
///
/// The header is deliberately the same shape, the same columns and the same colours as
/// `ThinkingRowView`, because the stored row replaces this one mid sentence and anything that
/// disagrees shows up as a jump.
struct StreamingThinkingView: View {
    var text: String
    var tokens: Int

    private static let tailLimit = 600

    private var tail: String {
        text.count <= Self.tailLimit
            ? text
            : "\u{2026}" + String(text.suffix(Self.tailLimit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Text(tail)
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
                .italic()
                .lineSpacing(TranscriptLayout.proseLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, TranscriptLayout.detailIndent)
                .padding(.trailing, TranscriptLayout.inset)
                .padding(.bottom, TranscriptLayout.block)
        }
    }

    private var header: some View {
        HStack(spacing: TranscriptLayout.glyphGap) {
            TranscriptGlyph(symbol: "sparkle")

            Text("Thinking")
                .font(Typo.labelEmphasis)
                .foregroundStyle(Palette.textSecondary)
                .italic()
                .lineLimit(1)
                .transcriptLabelColumn()

            if tokens > 0 {
                Text("\(tokens) tokens")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textTertiary)
                    .monospacedDigit()
                    .fixedSize()
            }

            Spacer(minLength: TranscriptLayout.tight)
        }
        .transcriptRowFrame()
    }
}
