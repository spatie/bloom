import SwiftUI
import BloomCore

/// One stored event, rendered.
///
/// The row decodes its own payload, and it does it here rather than up front. A session can hold
/// tens of thousands of rows and the enclosing `LazyVStack` only ever builds the handful on screen,
/// so decoding here is the difference between opening a long transcript instantly and parsing forty
/// megabytes of JSON before the first frame. Every decode goes through `TranscriptEventCache`, so a
/// row that is rebuilt on every streamed token still only parses once.
///
/// This view decides which kind of row it is and hands the decoded payload to the view that draws
/// it. Every kind except assistant prose, a user turn and an expanded row is exactly one line tall.
/// That is the whole design: an agent run reads as a list of actions, not a chat log.
struct TranscriptRowView: View, Equatable {
    /// A row redraws when what it holds changes, and not because the closure beside it is a new
    /// closure. Functions are never equal to one another, so without this SwiftUI has to assume
    /// every row differs from the one it drew a moment ago.
    ///
    /// **Written out field by field, and it must stay that way.** `lhs.row == rhs.row` is one
    /// character shorter and it compares `payload: Data` byte by byte, which in a real session is
    /// 1.6MB of JSON across 189 rows, on the main thread, on every layout pass. Dragging the
    /// sidebar divider runs a layout pass per frame, so the comparison that exists to avoid work
    /// was doing more work than the redraw it prevented. Both `Data.==` and
    /// `TranscriptRow.__derived_struct_equals` showed up on the drag path in a profile.
    ///
    /// What is compared instead is what identifies the row and what can change about it after it
    /// has been stored. `id` and `seq` name a persisted message, whose payload is written once and
    /// never rewritten. `resultPayload` arrives later, and its length is enough to see it arrive
    /// or grow without reading it. `isError` and `durationMS` are set at the same moment. The
    /// workspace is compared on the two fields a row actually reads, which are where its file
    /// chips open and which model they open into.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row.id == rhs.row.id
            && lhs.row.seq == rhs.row.seq
            && lhs.row.kind == rhs.row.kind
            && lhs.row.isError == rhs.row.isError
            && lhs.row.refusal == rhs.row.refusal
            && lhs.row.refusalReason == rhs.row.refusalReason
            && lhs.row.durationMS == rhs.row.durationMS
            && lhs.row.resultPayload?.count == rhs.row.resultPayload?.count
            && lhs.row.parentToolUseID == rhs.row.parentToolUseID
            && lhs.isExpanded == rhs.isExpanded
            && lhs.isNested == rhs.isNested
            && lhs.maxBubbleWidth == rhs.maxBubbleWidth
            && lhs.workspace.id == rhs.workspace.id
            && lhs.workspace.path == rhs.workspace.path
            // A question being answered has to redraw the row that asked it, and the decision is
            // the only thing about it that changes after it is stored.
            && lhs.row.permissionDecision == rhs.row.permissionDecision
            && lhs.row.permissionNote == rhs.row.permissionNote
            && lhs.projectName == rhs.projectName
    }

    var row: TranscriptRow
    /// Which worktree the row's paths are relative to, and where a file chip opens. Read by a user
    /// turn's attachment chips and by the file chips in a tool row, and constant for a whole
    /// transcript, so it is handed down rather than looked up per row.
    var workspace: Workspace
    var isExpanded = false
    var isNested = false
    /// The width a user bubble is allowed to fill, handed down because the enclosing scroll view
    /// already measured it and a per row measurement would not size to its content.
    var maxBubbleWidth: CGFloat = 560
    /// What the project is called, so a permission row can name where a rule would apply. Handed
    /// down for the same reason `workspace` is: it is constant for a whole transcript.
    var projectName: String = ""
    var onToggle: () -> Void = {}
    /// Answering a permission question. Never a user turn: it writes a control response that
    /// unblocks a turn already in flight.
    var onAnswer: (String, PermissionDecision) -> Void = { _, _ in }

    var body: some View {
        content
            .padding(.leading, isNested ? TranscriptLayout.nestIndent : 0)
            .overlay(alignment: .leading) {
                if isNested {
                    Rectangle()
                        .fill(Palette.border)
                        .frame(width: Metrics.hairline)
                        .padding(.leading, TranscriptLayout.inset)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch row.kind {
        case .user:
            // Read once for the row. It walks the stored request's content blocks and joins them,
            // and both branches below need it: the second used to reach it through `userTurn`, so
            // an ordinary bubble built the same string twice per pass.
            let typed = userText
            // A review turn first: its message is mostly scaffolding the reader never typed, so
            // it renders as the typed words plus a chip per comment. `split` is strict and
            // returns nil for everything else, which falls through to the ordinary bubble.
            if let review = ReviewTurn.split(typed) {
                UserTurnRowView(
                    text: review.message,
                    reviewChips: review.chips,
                    workspace: workspace,
                    maxWidth: maxBubbleWidth
                )
            } else {
                // Attachments reach the agent as paths in the prompt text, which is the only
                // reference every agent can follow, so this is the point where they are taken back
                // out of the sentence and handed to the row as files. `AttachmentTrailer.split`
                // returns the text untouched at the first thing that is not exactly the shape the
                // composer writes, so a message that merely talks about attached files is never
                // edited.
                let turn = AttachmentTrailer.split(typed)
                UserTurnRowView(
                    text: turn.body,
                    attachments: turn.paths,
                    workspace: workspace,
                    maxWidth: maxBubbleWidth
                )
            }

        case .assistantText:
            if let text = assistantText, !text.isEmpty {
                ProseRowView(text: text)
            }

        case .thinking:
            if let text = thinkingText, !text.isEmpty {
                ThinkingRowView(text: text, isExpanded: isExpanded, onToggle: onToggle)
            }

        case .toolUse:
            if let use = toolUse {
                ToolRowView(
                    use: use,
                    presentation: TranscriptPresentationCache.presentation(rowID: row.id, use: use),
                    workspace: workspace,
                    result: toolResult,
                    isError: row.isError,
                    refusal: row.refusal,
                    refusalReason: row.refusalReason,
                    durationMS: row.durationMS,
                    isExpanded: isExpanded,
                    onToggle: onToggle
                )
            }

        case .toolResult:
            if let result = orphanResult {
                OrphanResultRowView(result: result)
            }

        case .permissionAsk:
            if let ask = permissionAsk {
                // A question is not a permission request, however it travels. See
                // `AgentQuestionCard` for what drawing it as one did.
                if AgentQuestionnaire.isQuestion(toolName: ask.toolName) {
                    AgentQuestionCard(
                        ask: ask,
                        decision: row.permissionDecision,
                        onAnswer: { onAnswer(ask.requestID, $0) }
                    )
                } else {
                    PermissionAskRowView(
                        ask: ask,
                        decision: row.permissionDecision,
                        note: row.permissionNote,
                        projectName: projectName,
                        onAnswer: { onAnswer(ask.requestID, $0) }
                    )
                }
            }

        case .error:
            AgentErrorRowView(
                exit: AgentExit.read(json),
                isExpanded: isExpanded,
                onToggle: onToggle
            )

        case .notice:
            RateLimitRowView(payload: row.payload)

        case .system:
            if let info = initInfo {
                SessionStartRowView(info: info)
            }

        // A result row is a turn boundary, and the footer that renders it needs the rows around it,
        // so TranscriptView draws that one itself.
        case .result:
            EmptyView()
        }
    }

    // MARK: Decoding

    private var event: AgentEvent? {
        TranscriptEventCache.event(rowID: row.id, payload: row.payload)
    }

    private var json: JSONValue? {
        TranscriptEventCache.json(rowID: row.id, payload: row.payload)
    }

    private var assistantText: String? {
        guard case .assistantText(let block)? = event else { return nil }
        return block.text
    }

    private var thinkingText: String? {
        guard case .thinking(let block)? = event else { return nil }
        return block.text
    }

    private var toolUse: AgentToolUse? {
        guard case .toolUse(let use)? = event else { return nil }
        return use
    }

    /// A tool result whose call never made it into the transcript. Rare, but it must not vanish.
    private var orphanResult: AgentToolResult? {
        guard case .toolResult(let result)? = event else { return nil }
        return result
    }

    /// The question, decoded from the row that recorded it. Goes through the same cache as every
    /// other payload, so a row rebuilt on every streamed token still parses once.
    private var permissionAsk: PermissionAsk? {
        guard case .permissionAsk(let ask)? = event else { return nil }
        return ask
    }

    private var initInfo: AgentInit? {
        guard case .initialized(let info)? = event else { return nil }
        return info
    }

    /// Only decoded once a row is open, because a tool result is the largest payload in the file.
    private var toolResult: AgentToolResult? {
        guard isExpanded, let payload = row.resultPayload,
              case .toolResult(let result)? = TranscriptEventCache.event(rowID: row.id, payload: payload)
        else { return nil }
        return result
    }

    /// A user turn is the line Bloom itself wrote to stdin, so it is read straight out of the
    /// stored request rather than through the event decoder, which only knows about tool results.
    private var userText: String {
        guard let blocks = json?["message"]?["content"]?.arrayValue else { return "" }
        return blocks
            .compactMap { $0["text"]?.stringValue }
            .joined(separator: "\n")
    }
}
