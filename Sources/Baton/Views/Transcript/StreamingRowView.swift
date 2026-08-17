import SwiftUI
import BatonCore

/// The live tail of the turn: what is arriving right now, before the CLI emits the finished block.
///
/// This is the one row allowed to grow past a single line, because it is the row the user is
/// actually watching. Text is rendered as plain `Text` rather than markdown on purpose: this view
/// rebuilds on every delta, and parsing markdown per token is not something a transcript can
/// afford. The finished block lands a moment later and is rendered properly then.
struct StreamingRowView: View {
    let transcript: TranscriptModel

    /// Streaming thinking is a scroll of consciousness. Only the tail is interesting, and only the
    /// tail is cheap.
    private static let thinkingTailLimit = 600

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !transcript.streamingThinking.isEmpty {
                thinking
            }
            if !transcript.streamingText.isEmpty {
                Text(transcript.streamingText)
                    .font(Typo.body)
                    .foregroundStyle(Palette.textPrimary)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
            }
            if let tool = transcript.streamingToolName {
                status(glyph: "gearshape", text: "Running \(tool)")
            } else if transcript.isRunning, !hasVisibleStream {
                status(glyph: nil, text: transcript.statusLabel ?? "Working")
            }
        }
        .padding(.vertical, 4)
        .transaction { $0.animation = nil }
    }

    private var hasVisibleStream: Bool {
        !transcript.streamingThinking.isEmpty || !transcript.streamingText.isEmpty
    }

    private var thinking: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: TranscriptLayout.glyphGap) {
                Image(systemName: "sparkle")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textTertiary)
                    .frame(width: TranscriptLayout.glyphWidth)
                Text("Thinking")
                    .font(Typo.labelEmphasis)
                    .foregroundStyle(Palette.textSecondary)
                    .italic()
                if transcript.thinkingTokens > 0 {
                    Text("\(transcript.thinkingTokens) tokens")
                        .font(Typo.micro)
                        .foregroundStyle(Palette.textTertiary)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }

            Text(tail(transcript.streamingThinking))
                .font(Typo.label)
                .foregroundStyle(Palette.textTertiary)
                .italic()
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, TranscriptLayout.detailIndent)
        }
        .padding(.horizontal, 6)
    }

    private func status(glyph: String?, text: String) -> some View {
        HStack(spacing: TranscriptLayout.glyphGap) {
            Group {
                if let glyph {
                    Image(systemName: glyph)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.running)
                } else {
                    ActivityDot(isActive: true)
                }
            }
            .frame(width: TranscriptLayout.glyphWidth)

            Text(text)
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: Metrics.rowHeight)
    }

    private func tail(_ text: String) -> String {
        text.count <= Self.thinkingTailLimit
            ? text
            : "\u{2026}" + String(text.suffix(Self.thinkingTailLimit))
    }
}
