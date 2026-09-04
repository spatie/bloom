import SwiftUI
import BloomCore

/// The centre column while a subagent is selected: what it was asked or what it ran, what it has
/// been doing, and what it answered.
///
/// **Everything else in the window keeps showing the parent workspace.** The terminal is still the
/// worktree's terminal, the diff is still the worktree's diff, the composer still sends to the
/// chat that spawned this. See `SidebarSelection.subagent`, which is where that decision lives:
/// it answers `workspaceID` with the parent, so every pane that hangs off the selection carries on
/// unchanged and this is the only one that had to notice.
///
/// **What it reads.** `system/task_notification.output_file`, which is the CLI's own record for
/// that task. For an agent it is a symlink to NDJSON in Claude Code's transcript shape, written
/// for a failed subagent as readily as for one that worked (measured, not assumed: see
/// `SubagentTranscript`). For a background command it is plain stdout, and reading one as the
/// other is what used to leave this pane with a title and a single sentence in it. Bloom does not
/// own the file, so every way of failing to read it is a sentence.
///
/// **And what it reads before that file exists**, which is the whole of a running subagent: the
/// path is named on the line that ENDS the task, so until then there is nothing on disk to open.
/// The lines the subagent produced came past on the parent's own stream carrying its
/// `parent_tool_use_id` and Bloom stored every one of them, so the pane falls back to those. See
/// `SubagentTranscript.live(streamLines:sessionID:)` and
/// `WorkspaceModel.subagentStreamLines(forToolUseID:)`.
///
/// **It stays live while the subagent works**, which is the case it is most often opened in. The
/// brief is known the moment the task starts, so it is on screen immediately; the output file
/// grows under the CLI's hand, so it is re-read on `SubagentPane.refreshSeconds`. The version
/// before this keyed its one read on the subagent's state, so a pane opened mid run showed
/// whatever prefix existed at the instant it was opened and then nothing more until the end.
///
/// **What it does NOT do any more is draw the conversation itself.** It used to put a caption and
/// a `Text` over every entry, which is a second renderer for the thing the pane beside it already
/// renders, and it lost every argument that one had won: an answer written in markdown arrived as
/// literal asterisks, and a Bash call arrived as a screen of pretty printed JSON where the
/// transcript draws one line with the command in it. `SubagentConversationView` hands the rows to
/// `TranscriptRowView`, which is the only thing in the window that decides how a row is drawn.
///
/// Everything decided is decided in `SubagentPane`, `SubagentKind` and `SubagentTranscript`.
struct SubagentOutputView: View {
    var model: WorkspaceModel
    var subagentID: SubagentID

    /// The conversation, already folded into rows. Rows rather than the messages they came from,
    /// because folding a result onto its call parses the largest payload in the file and this
    /// runs once a second: see `load`, which does it off the main actor.
    @State private var reading = SubagentReading()
    @State private var failure: SubagentOutput.Failure?
    @State private var isBriefExpanded = false

    /// The conversation's text size, face and line height, read here for the reason `ChatPaneView`
    /// reads them: this pane is a conversation, and a reader who has set the transcript larger has
    /// not asked for a subagent's half of it to stay small.
    @AppStorage(ChatTextSize.defaultsKey) private var textSize = ChatTextSize.standard
    @AppStorage(ChatFont.defaultsKey) private var chatFontID = ChatFont.standardID
    @AppStorage(ChatLineHeight.defaultsKey) private var lineHeight = ChatLineHeight.standard

    private var subagent: Subagent? {
        model.activeTranscript?.subagents[subagentID]
    }

    private var kind: SubagentKind { subagent?.kind ?? .agent }

    /// Where this subagent's paths point. The parent's worktree, because a subagent runs in it.
    private var home: TranscriptHome {
        model.activeTranscript?.home ?? TranscriptHome(model.workspace)
    }

    var body: some View {
        ScrollView {
            // Plain, with the lazy stack one level down in `SubagentConversationView`. Two nested
            // lazy stacks is the outer one measuring the inner one whole, which is the laziness
            // this pane actually needs given away to get it on the three views above.
            VStack(alignment: .leading, spacing: 0) {
                if let subagent {
                    header(subagent)
                    brief(subagent)
                } else {
                    // Only reachable if the turn was cleared out from under the selection, which
                    // the next turn starting does by design.
                    Text("That subagent belonged to a turn that has since been replaced.")
                        .font(Typo.body)
                        .foregroundStyle(Palette.textSecondary)
                        .padding(.horizontal, TranscriptLayout.inset)
                }

                output
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Metrics.pane)
        }
        .background(Palette.windowBackground)
        .environment(\.fontScale, textSize.scale)
        .environment(\.chatFont, ChatFont(rawValue: chatFontID))
        .environment(\.chatLineHeight, lineHeight)
        // What a link in a subagent's answer does when it is pressed, which is what it does in the
        // transcript: one rule for every address the window draws. See `TranscriptLink.actions`.
        .markdownLinkActions(TranscriptLink.actions(for: model))
        // Re-read when the selection moves to a different subagent, and when this one ends. The
        // running case keeps re-reading inside the task rather than re-keying it: an id that
        // carried the elapsed seconds would tear the whole pane down and rebuild it once a second,
        // losing the scroll position and any brief the reader had just opened.
        .task(id: subagentID) { await follow() }
    }

    /// Read the file, and keep reading it for as long as the task is running.
    private func follow() async {
        isBriefExpanded = false
        await load()
        while !Task.isCancelled, SubagentPane.refreshes(subagent) {
            try? await Task.sleep(for: .seconds(SubagentPane.refreshSeconds))
            guard !Task.isCancelled else { return }
            await load()
        }
        // One last read after it ends. The CLI writes the notification and the last lines of the
        // file at very nearly the same moment, and without this the pane could keep the read it
        // took a fraction of a second before the answer landed.
        await load()
    }

    private func load() async {
        // Off the main actor. A subagent's transcript is small in the capture and is not promised
        // to be, and this now runs once a second rather than once. Folding the messages into rows
        // goes with it: pairing a result onto its call decodes the result payload, which is the
        // largest one in the file.
        let path = subagent?.outputFile
        let kind = kind
        let session = model.activeTranscript?.session.id ?? SessionID("")
        // Read on the main actor, parsed off it. These are rows the transcript owns.
        let lines = kind == .agent ? model.subagentStreamLines(forToolUseID: toolUseID) : []
        let result = await Task.detached { () -> Result<SubagentReading, SubagentOutput.Failure> in
            switch SubagentOutput.read(path: path, kind: kind, sessionID: session) {
            case .success(let parsed):
                return .success(SubagentReading(parsed))
            case .failure(let reason):
                // **What Bloom saw, when the CLI has not written anything to read.** This is the
                // whole of a running subagent's pane: the file is named on the line that ends it,
                // so for the length of the run the read above can only fail. Falling back rather
                // than replacing, because once the file is there it is the CLI's own record of
                // the task and this is a copy of what went past. See
                // `SubagentTranscript.live(streamLines:sessionID:)`.
                let live = SubagentTranscript.live(streamLines: lines, sessionID: session)
                return live.isEmpty ? .failure(reason) : .success(SubagentReading(live))
            }
        }.value
        switch result {
        case .success(let parsed):
            reading = parsed
            failure = nil
        case .failure(let reason):
            reading = SubagentReading()
            failure = reason
        }
    }

    /// The Task call this subagent hangs off, which is how its nested rows are found.
    private var toolUseID: String { subagent?.toolUseID ?? "" }

    // MARK: - Parts

    private func header(_ subagent: Subagent) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            HStack(spacing: Metrics.spacingSmall) {
                SubagentMarkGlyph(mark: SubagentRow(subagent).mark)
                Text(SubagentRow.title(of: subagent))
                    .font(Typo.title)
            }

            Text(SubagentPane.subtitle(subagent))
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)

            // The whole of it, not the row's truncation. The row has 260 points and this pane is
            // the place the sentence is allowed to be a sentence.
            if !subagent.summary.isEmpty {
                Text(subagent.summary)
                    .font(Typo.body)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, TranscriptLayout.inset)
        .padding(.bottom, TranscriptLayout.block)
    }

    /// What it was given to do: a prompt for an agent, a command line for a background command.
    ///
    /// The prompt arrives on `task_started` and is therefore on screen from the first frame, which
    /// is the half of this that is useful before the task has finished. A command line arrives
    /// nowhere on the task's own lines, so it is lifted back out of the parent's Bash call: see
    /// `SubagentPane.commandLine`.
    ///
    /// **A long one opens shut**, showing the line that opens it and nothing else. See
    /// `SubagentPane.briefCollapseLimit` for why: the head it used to show filled the pane with
    /// the reader's own words and pushed what the subagent DID below the fold.
    ///
    /// A prompt is markdown that somebody wrote, so it is rendered as the markdown it is, by the
    /// same view that renders an answer. Set as literal text it arrived full of `**` and backticks,
    /// which is the complaint that started all of this.
    @ViewBuilder
    private func brief(_ subagent: Subagent) -> some View {
        let text = briefText(subagent)
        if !text.isEmpty {
            let collapses = SubagentPane.briefCollapses(text)
            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                caption(SubagentPane.briefLabel(subagent.kind))
                    .padding(.horizontal, TranscriptLayout.inset)

                if collapses {
                    Button(SubagentPane.briefToggle(isExpanded: isBriefExpanded, kind: subagent.kind)) {
                        isBriefExpanded.toggle()
                    }
                    .buttonStyle(.link)
                    .font(Typo.caption)
                    .padding(.horizontal, TranscriptLayout.inset)
                }

                if !collapses || isBriefExpanded {
                    if SubagentPane.briefIsCode(subagent.kind) {
                        DetailCodeBlock(text: text, copyTitle: "Copy the command")
                            .padding(.horizontal, TranscriptLayout.inset)
                    } else {
                        ProseRowView(text: text)
                    }
                }
            }
            .padding(.bottom, TranscriptLayout.block)
        }
    }

    private func briefText(_ subagent: Subagent) -> String {
        switch subagent.kind {
        // `task_started` is the honest copy and it is gone with the turn that carried it, so the
        // one read back out of the transcript stands in for a pane opened after that.
        case .agent: subagent.prompt.isEmpty ? reading.prompt : subagent.prompt
        case .command: model.commandLine(forToolUseID: subagent.toolUseID) ?? ""
        }
    }

    @ViewBuilder
    private var output: some View {
        if let failure {
            Text(SubagentPane.nothingToShow(
                failure, kind: kind, isRunning: subagent?.state == .running
            ))
                .font(Typo.body)
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, TranscriptLayout.inset)
        } else if !reading.printed.isEmpty {
            // A background command has no conversation in it. What it has to say is the bytes it
            // wrote to a terminal, which are code and are set as code.
            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                caption(SubagentPane.outputLabel(.command))
                DetailCodeBlock(text: reading.printed, copyTitle: "Copy the output")
            }
            .padding(.horizontal, TranscriptLayout.inset)
        } else {
            SubagentConversationView(
                rows: reading.rows, home: home, droppedRows: reading.droppedRows
            )
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Typo.micro)
            .tracking(Typo.microTracking)
            .foregroundStyle(Palette.textTertiary)
    }
}

/// One read's worth of pane, folded into rows and assigned in one go.
///
/// A value rather than four pieces of `@State`, so a re-read can never leave the rows of one
/// moment beside the dropped count of another. Outside the view rather than nested in it because
/// it is built off the main actor and a type nested in a `View` inherits that view's isolation.
///
/// `TranscriptModel.rows(from:)` is the transcript's own fold, used rather than copied for the
/// reason its doc comment gives: which result belongs to which call is decided once for every
/// conversation in the window.
private struct SubagentReading: Equatable, Sendable {
    var rows: [TranscriptRow] = []
    var droppedRows = 0
    /// What a background command printed. Empty for an agent.
    var printed = ""
    /// The brief as the source carried it, used only when the roster has lost the task that
    /// carried it.
    var prompt = ""

    init() {}

    init(_ transcript: SubagentTranscript) {
        rows = TranscriptModel.rows(from: transcript.messages)
        droppedRows = transcript.droppedRows
        printed = transcript.printed
        prompt = transcript.prompt
    }
}
