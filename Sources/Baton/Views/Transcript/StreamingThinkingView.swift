import SwiftUI

/// Reasoning as it arrives.
///
/// Streaming thinking is a scroll of consciousness. Only the tail is interesting, and only the tail
/// is cheap: laying out a hundred kilobytes of italic text on every delta is not something a
/// transcript can afford.
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
        VStack(alignment: .leading, spacing: TranscriptLayout.tight) {
            HStack(spacing: TranscriptLayout.glyphGap) {
                TranscriptGlyph(symbol: "sparkle")

                Text("Thinking")
                    .font(Typo.labelEmphasis)
                    .foregroundStyle(Palette.textSecondary)
                    .italic()

                if tokens > 0 {
                    Text("\(tokens) tokens")
                        .font(Typo.micro)
                        .foregroundStyle(Palette.textTertiary)
                        .monospacedDigit()
                }

                Spacer(minLength: 0)
            }

            Text(tail)
                .font(Typo.label)
                .foregroundStyle(Palette.textTertiary)
                .italic()
                .lineSpacing(TranscriptLayout.tight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, TranscriptLayout.detailIndent)
        }
        .padding(.horizontal, TranscriptLayout.inset)
    }
}
