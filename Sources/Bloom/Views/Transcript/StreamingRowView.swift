import SwiftUI

/// The live tail of the turn: what is arriving right now, before the CLI emits the finished block.
///
/// This is the one row allowed to grow past a single line, because it is the row the user is
/// actually watching.
///
/// It uses the same columns as a stored row, so the moment a streamed line is replaced by its
/// persisted twin nothing moves. A transcript that jumps as rows land is the main way this screen
/// reads as unfinished. That is why the text goes through `MarkdownView`, the renderer the stored
/// row uses, rather than the plain `Text` it used to: drawn raw, a fenced block showed its own
/// backtick fence markers as prose for the length of the answer and then turned into a titled code
/// block with a copy button the instant the turn ended, which is exactly the jump the columns are
/// lined up to avoid. An agent writes fenced code in most answers of any length, so this was most
/// answers.
///
/// The reason it was plain `Text` was cost, and that was worth measuring rather than assuming.
/// A release build parses a finished 2KB answer in 1.1ms and a 10KB one in 2.9ms; the worst single
/// delta over a whole 10KB stream measured 2.7ms, well inside a frame, and the parser was written
/// for this (`MarkdownParser` is a bounded hand-written scanner, and every prefix of a document
/// parses). What it must not do is evict the transcript's parse cache one prefix at a time, which
/// is why streaming text is parsed through a slot of its own.
///
/// A fence that has not closed yet is not a problem to be worked around: `parseFence` runs to the
/// end of the input and hands back a code block whether the closing marker has arrived or not, so
/// the block appears the moment the opening marker does and then grows. Nothing swaps layout when
/// the fence completes. `MarkdownParserTests` holds that property down.
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
                MarkdownView(transcript.streamingText, isStreaming: true)
                    .font(Typo.body)
                    .lineSpacing(TranscriptLayout.proseLeading)
                    .textSelection(.enabled)
                    // The same measure the stored prose row uses, or the line the user is
                    // watching rewraps the instant it is replaced by its persisted twin.
                    .frame(maxWidth: TranscriptLayout.proseMeasure, alignment: .leading)
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
