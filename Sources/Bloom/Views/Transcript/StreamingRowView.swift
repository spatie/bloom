import SwiftUI
import BloomCore

/// The live tail of the turn: what is arriving right now, before the CLI emits the finished block.
///
/// This is the one row allowed to grow past a single line, because it is the row the user is
/// actually watching.
///
/// It uses the same columns as a stored row. Live Markdown is flattened into one styled text view
/// while it grows, then the settled answer gains the full block layout and controls. Keeping one
/// live view avoids the SwiftUI stack layout crashes seen when a long answer changed its block
/// tree on every delta.
///
/// ## What fades here, and what must never
///
/// **The block fades in once, when it first has anything in it. The text inside it never does.**
/// A delta is a handful of characters arriving many times a second, so an animation started per
/// delta is a new implicit animation per token, all of them fighting over the same layout, and
/// what that looks like is a shimmer running down the tail of the answer. That is a good deal
/// worse than the pop it would be replacing, which is why `.transaction { $0.animation = nil }`
/// is still on every piece below and why it has been pushed onto the pieces rather than left on
/// the stack around them.
///
/// What was actually popping is the moment the answer starts: the turn shows "Working", and then
/// a paragraph of prose is on screen in one frame where a status line was. That is a block
/// arriving in front of the reader. `MessageArrival` gives it a short fade with a clock that
/// follows it into the saved row, honouring Reduce Motion. Once per block, nothing per delta.
struct StreamingRowView: View {
    let transcript: TranscriptModel

    private var hasVisibleStream: Bool {
        !transcript.streamingThinking.isEmpty || !transcript.streamingText.isEmpty
    }

    /// Compaction is the one status that is not the agent working for you, so it is the one that
    /// does not get the running dot. Read off the label rather than off a second piece of state,
    /// because the label is what the CLI said and there is nothing else to know: see
    /// `ContextCompaction.isCompacting`.
    private func mark(for label: String) -> StreamingStatusView.Mark {
        ContextCompaction.isCompacting(status: label)
            ? .housekeeping(CompactionBoundaryRowView.symbol)
            : .activity
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
                .transaction { $0.animation = nil }
                .messageArrival(transcript.messageArrivals.stream(.thinking))
            }

            if !transcript.streamingText.isEmpty {
                ProseRowView(text: transcript.streamingText, isStreaming: true, copyText: nil)
                    // Streamed text arrives many times a second, and every one of those deltas
                    // runs through here. Nothing inside this block may carry an animation: see
                    // the note under `body`.
                    .transaction { $0.animation = nil }
                    // Outside the transaction above, and that is the whole of why it works. The
                    // modifier clears the animation for what it wraps, and the opacity this adds
                    // sits above it, so the block's own settle survives while the text under it
                    // stays as sudden as it was.
                    .messageArrival(transcript.messageArrivals.stream(.assistantText))
            }

            // Before the status line and in place of it, because it is the same slot answering
            // the same question with more of the truth. "Requesting" beside a live dot for three
            // minutes is what the retry row exists to replace, and leaving both on screen would
            // have the tail say the turn is requesting and waiting to request in two rows.
            if let run = transcript.retryRun {
                RetryRowView(run: run)
                    .transaction { $0.animation = nil }
            } else if let tool = transcript.streamingTool {
                if tool.startedAt == nil {
                    StreamingStatusView(mark: .tool("gearshape"), text: tool.label)
                        .transaction { $0.animation = nil }
                } else {
                    // The model owns when the call began; this clock only redraws the readout. A
                    // result removes the view, so nothing keeps ticking after the work is over.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        StreamingStatusView(mark: .tool("gearshape"), text: tool.text(at: context.date))
                    }
                    .transaction { $0.animation = nil }
                }
            } else if transcript.isRunning || transcript.sending != nil, !hasVisibleStream {
                // Reserve the activity line with the instant echo so starting the agent does
                // not insert another row underneath a bubble that is still arriving.
                let label = transcript.statusLabel ?? (transcript.isRunning ? "Working" : "Starting")
                StreamingStatusView(mark: mark(for: label), text: label)
                    .transaction { $0.animation = nil }
            }
        }
    }
}
