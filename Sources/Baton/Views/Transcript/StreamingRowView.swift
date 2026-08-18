import SwiftUI
import BatonCore

/// The live tail of the turn: what is arriving right now, before the CLI emits the finished block.
///
/// This is the one row allowed to grow past a single line, because it is the row the user is
/// actually watching. Text is rendered as plain `Text` rather than markdown on purpose: this view
/// rebuilds on every delta, and parsing markdown per token is not something a transcript can
/// afford. The finished block lands a moment later and is rendered properly then.
///
/// It uses the same columns as a stored row, so the moment a streamed line is replaced by its
/// persisted twin nothing moves. A transcript that jumps as rows land is the main way this screen
/// reads as unfinished.
struct StreamingRowView: View {
    let transcript: TranscriptModel

    /// Streaming thinking is a scroll of consciousness. Only the tail is interesting, and only the
    /// tail is cheap.
    private static let thinkingTailLimit = 600

    var body: some View {
        VStack(alignment: .leading, spacing: TranscriptLayout.inset) {
            if !transcript.streamingThinking.isEmpty {
                thinking
            }
            if !transcript.streamingText.isEmpty {
                Text(transcript.streamingText)
                    .font(Typo.body)
                    .foregroundStyle(Palette.textPrimary)
                    .lineSpacing(TranscriptLayout.proseLeading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, TranscriptLayout.inset)
            }
            if let tool = transcript.streamingToolName {
                status(glyph: "gearshape", text: "Running \(tool)")
            } else if transcript.isRunning, !hasVisibleStream {
                status(glyph: nil, text: transcript.statusLabel ?? "Working")
            }
        }
        .padding(.vertical, TranscriptLayout.tight * 2)
        .transaction { $0.animation = nil }
    }

    private var hasVisibleStream: Bool {
        !transcript.streamingThinking.isEmpty || !transcript.streamingText.isEmpty
    }

    private var thinking: some View {
        VStack(alignment: .leading, spacing: TranscriptLayout.tight) {
            HStack(spacing: TranscriptLayout.glyphGap) {
                TranscriptGlyph(symbol: "sparkle")
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
                .lineSpacing(TranscriptLayout.tight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, TranscriptLayout.detailIndent)
        }
        .padding(.horizontal, TranscriptLayout.inset)
    }

    private func status(glyph: String?, text: String) -> some View {
        HStack(spacing: TranscriptLayout.glyphGap) {
            Group {
                if let glyph {
                    TranscriptGlyph(symbol: glyph, tint: Palette.running)
                } else {
                    ActivityDot(isActive: true)
                        .frame(width: TranscriptLayout.glyphWidth)
                }
            }

            Text(text)
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, TranscriptLayout.inset)
        .frame(height: Metrics.rowHeight)
    }

    private func tail(_ text: String) -> String {
        text.count <= Self.thinkingTailLimit
            ? text
            : "\u{2026}" + String(text.suffix(Self.thinkingTailLimit))
    }
}
