import SwiftUI

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

    private var hasVisibleStream: Bool {
        !transcript.streamingThinking.isEmpty || !transcript.streamingText.isEmpty
    }

    var body: some View {
        // Spacing 0, like the stored row list: each piece below carries the same padding its
        // persisted twin does, so replacing one with the other moves nothing.
        VStack(alignment: .leading, spacing: 0) {
            if !transcript.streamingThinking.isEmpty {
                StreamingThinkingView(
                    text: transcript.streamingThinking,
                    tokens: transcript.thinkingTokens
                )
            }

            if !transcript.streamingText.isEmpty {
                Text(transcript.streamingText)
                    .font(Typo.body)
                    .foregroundStyle(Palette.textPrimary)
                    .lineSpacing(TranscriptLayout.proseLeading)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, TranscriptLayout.inset)
                    .padding(.vertical, TranscriptLayout.inset)
            }

            if let tool = transcript.streamingToolName {
                StreamingStatusView(glyph: "gearshape", text: "Running \(tool)")
            } else if transcript.isRunning, !hasVisibleStream {
                StreamingStatusView(glyph: nil, text: transcript.statusLabel ?? "Working")
            }
        }
        // Streamed text arrives many times a second. Animating it would mean a new implicit
        // animation per token, all of them fighting over the same layout.
        .transaction { $0.animation = nil }
    }
}
