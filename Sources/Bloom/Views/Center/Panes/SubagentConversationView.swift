import SwiftUI
import BloomCore

/// A subagent's own conversation, drawn the way the chat draws one.
///
/// **The owner's report**: clicking into a background subagent opened a pane that looked nothing
/// like the chat. An uppercase "Asked" and a "Show the prompt" link where the prompt should be, and
/// then every tool call and every thinking block as a row of its own, flush left and the full width
/// of the pane. The rows were already the transcript's rows; everything around them was not.
///
/// So everything around them is the chat's now, piece by piece, and nothing is restyled to look
/// like it:
///
/// - the prompt is `UserTurnRowView`, the chat's own bubble;
/// - the work is folded by `SubagentConversation`, which is `TranscriptFold` with the pane's two
///   differences written down and tested, and drawn with `TranscriptFoldRowView`;
/// - every row, thinking and prose included, is `TranscriptRowView`, so a thinking block is the
///   Thinking box and the answer is the markdown the chat draws;
/// - while it works the tail is `StreamingStatusView`, the chat's working line;
/// - and all of it sits in the chat's reading column, `TranscriptLayout.conversationMeasure` wide
///   and centred, at the chat's insets.
///
/// **What it does not reuse is the list those pieces sit in**, and that is a measured choice
/// rather than an omission. `TranscriptListView` is an `NSTableView` built around one live
/// `TranscriptModel`: its session id keys the height cache, and its composer, queued deliveries,
/// unread mark, minimap and pane memory are all read off that model. A subagent has none of them,
/// and a `TranscriptModel` cannot be made for one without a session in the store. This is a lazy
/// stack over at most `SubagentTranscript.rowLimit` rows, where a row off screen is never built,
/// so the cost the table exists to remove is not being paid here.
///
/// The body is a list of views rather than a stack, so they flatten into the pane's own
/// `LazyVStack` and stay lazy. Two nested lazy stacks is the outer one measuring the inner whole.
struct SubagentConversationView: View {
    var rows: [TranscriptRow]
    /// The brief the subagent was handed, drawn as the turn that started it.
    var prompt: String
    /// Which worktree the rows' paths are relative to, and where a file chip opens. The parent's,
    /// because a subagent runs in the worktree its parent runs in.
    var home: TranscriptHome
    /// How many rows were dropped off the front to keep the pane bounded, drawn as a line saying
    /// so. A conversation that silently starts in the middle is a lie about what the subagent did.
    var droppedRows: Int
    var isRunning: Bool

    /// Which rows the reader has opened, by row id.
    ///
    /// The ids are derived from the payload rather than from the position (see
    /// `SubagentTranscript.rowID`), which is what keeps an opened row open across the once a second
    /// re-read and across the handover from the live stream to the file.
    @State private var expanded: Set<Int64> = []
    /// Which runs of work the reader has opened, by the id of each run's first row, for the same
    /// reason.
    @State private var unfolded: Set<Int> = []
    @State private var isPromptExpanded = false

    var body: some View {
        if !prompt.isEmpty {
            promptBubble
                .subagentReadingColumn()
        }

        if droppedRows > 0 {
            DetailCaption(text: "\(Counted.of(droppedRows, "earlier step")) not shown")
                .padding(.bottom, TranscriptLayout.block)
                .subagentReadingColumn()
        }

        ForEach(entries, id: \.id) { entry in
            content(for: entry)
                .subagentReadingColumn()
        }

        if isRunning {
            StreamingStatusView(glyph: nil, text: "Working")
                .padding(.bottom, TranscriptLayout.block)
                .subagentReadingColumn()
        }
    }

    /// Worked out on each pass. Five hundred rows at most, and every fact is read off the row
    /// without decoding its payload, which is the property the chat's fold is built on.
    private var entries: [SubagentConversation.Entry] {
        SubagentConversation.entries(
            facts: rows.map { $0.foldFact(seq: Int($0.id)) },
            unfolded: unfolded,
            revealed: Set(expanded.map { Int($0) })
        )
    }

    @ViewBuilder
    private func content(for entry: SubagentConversation.Entry) -> some View {
        switch entry {
        case let .fold(firstSeq, hiding, showsMore, isFolded):
            TranscriptFoldRowView(
                hiddenCount: hiding,
                showsMore: showsMore,
                isExpanded: !isFolded,
                onToggle: { toggle(&unfolded, firstSeq) }
            )
        case let .row(index, _):
            let row = rows[index]
            TranscriptRowView(
                row: row,
                home: home,
                isExpanded: expanded.contains(row.id),
                // Nil, because a subagent is never asked a permission question: the CLI puts
                // those on the parent's stream, where the transcript answers them.
                projectName: nil,
                onToggle: { toggle(&expanded, row.id) }
            )
        }
    }

    /// The brief, in the bubble the chat draws a prompt in.
    ///
    /// A long one opens shut on a few lines of itself, with the control every other folded block
    /// in the transcript uses under it. See `SubagentPane.briefPreview` for why it is shut at all,
    /// when the chat never shuts a bubble.
    @ViewBuilder
    private var promptBubble: some View {
        let preview = SubagentPane.briefPreview(prompt)
        VStack(alignment: .trailing, spacing: 0) {
            UserTurnRowView(text: isPromptExpanded ? prompt : (preview ?? prompt), home: home)

            if preview != nil {
                Button(TextFold.title(isExpanded: isPromptExpanded)) {
                    isPromptExpanded.toggle()
                }
                .linkButton()
                .font(Typo.caption)
                .accessibilityLabel(isPromptExpanded ? "Show less of the prompt" : "Show all of the prompt")
                .padding(.horizontal, TranscriptLayout.inset)
                .padding(.bottom, TranscriptLayout.inset)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func toggle<ID: Hashable>(_ set: inout Set<ID>, _ id: ID) {
        if set.contains(id) {
            set.remove(id)
        } else {
            set.insert(id)
        }
    }
}

extension View {
    /// The chat's reading column: the row inset `TranscriptListView` gives every entry, inside the
    /// measure `TranscriptTable` centres every row in. Both halves, because a row given only the
    /// measure sat a gutter to the left of the chat's, and one given only the inset ran the width
    /// of a wide pane, which is what the owner's screenshot showed.
    func subagentReadingColumn() -> some View {
        padding(.horizontal, TranscriptLayout.inset)
            .frame(maxWidth: TranscriptLayout.conversationMeasure, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}
