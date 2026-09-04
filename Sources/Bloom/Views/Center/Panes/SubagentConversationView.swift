import SwiftUI
import BloomCore

/// A subagent's own conversation, drawn with the rows the transcript beside it draws.
///
/// **This view exists so that there is one renderer for a conversation and not two.** The pane it
/// sits in used to draw a subagent's transcript itself: a caption and a `Text` per entry, which
/// meant markdown arrived as literal asterisks where the transcript renders prose, and a Bash call
/// arrived as a screen of pretty printed JSON where the transcript draws one line with the command
/// in it. Every one of those was a decision the transcript had already taken. `TranscriptRowView`
/// dispatches on the row's kind, `ProseRowView` renders the markdown, `ToolRowView` and
/// `ToolPresentation` draw the call, and this hands them rows.
///
/// **It deliberately does not fold.** `TranscriptFold` turns a run of grey activity rows into one
/// line, and main went in today with a change that folds a subagent's nested rows in the
/// transcript. That is the right answer there and the wrong one here, for two reasons. This is the
/// pane somebody opens BECAUSE the transcript folded the work away, so folding it again would
/// leave the detail nowhere to be seen. And the fold is a performance fix wearing a disclosure
/// triangle: it exists because the transcript's table keys, measures and builds every entry it is
/// handed, over a session that runs to thousands of rows. This is a `LazyVStack` over a bounded
/// `SubagentTranscript.rowLimit`, where a row off screen is never built at all, so the cost the
/// fold was written to remove is not being paid.
struct SubagentConversationView: View {
    var rows: [TranscriptRow]
    /// Which worktree the rows' paths are relative to, and where a file chip opens. The parent's,
    /// because a subagent runs in the worktree its parent runs in.
    var home: TranscriptHome
    /// How many rows were dropped off the front to keep the pane bounded, drawn as a line saying
    /// so. A conversation that silently starts in the middle is a lie about what the subagent did.
    var droppedRows: Int

    /// Which rows the reader has opened, by row id.
    ///
    /// Held here rather than in the pane above, so that the pane re-reading the file once a second
    /// does not touch it. The ids are derived from the payload rather than from the position (see
    /// `SubagentTranscript.rowID`), which is what keeps an opened row open across a re-read and
    /// across the handover from the live stream to the file.
    @State private var expanded: Set<Int64> = []

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if droppedRows > 0 {
                DetailCaption(text: "\(Counted.of(droppedRows, "earlier step")) not shown")
                    .padding(.horizontal, TranscriptLayout.inset)
                    .padding(.bottom, TranscriptLayout.block)
            }

            ForEach(rows) { row in
                TranscriptRowView(
                    row: row,
                    home: home,
                    isExpanded: expanded.contains(row.id),
                    // Nil, because a subagent is never asked a permission question: the CLI puts
                    // those on the parent's stream, where the transcript answers them.
                    projectName: nil,
                    onToggle: { toggle(row.id) }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggle(_ id: Int64) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
    }
}
