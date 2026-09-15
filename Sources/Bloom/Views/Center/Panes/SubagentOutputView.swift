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
/// output file grows under the CLI's hand, so it is re-read on `SubagentPane.refreshSeconds`, and
/// the view follows the newest row the way the chat does: while the reader is at the end, and not
/// once they have scrolled up to read something.
///
/// **An agent's pane reads like the chat**, because the owner asked why it did not. The
/// conversation is `SubagentConversationView`, which is the chat's own rows, fold, bubble and
/// working line in the chat's reading column. A background command has no conversation in it and
/// keeps the command line and what it printed, as code.
///
/// Everything decided is decided in `SubagentPane`, `SubagentKind`, `SubagentTranscript` and
/// `SubagentConversation`.
struct SubagentOutputView: View {
    var model: WorkspaceModel
    /// Which run: one the roster holds, opened from the sidebar or from a call row while it is
    /// still held, or one read back from the rows stored under its call. See `SubagentRunLink`.
    var target: SubagentRunLink.Target

    /// The conversation, already folded into rows. Rows rather than the messages they came from,
    /// because folding a result onto its call parses the largest payload in the file and this
    /// runs once a second: see `load`, which does it off the main actor.
    @State private var reading = SubagentReading()
    @State private var failure: SubagentOutput.Failure?
    @State private var isBriefExpanded = false

    /// Where the pane is scrolled to, standing at the bottom edge from the first frame.
    ///
    /// A position standing at `.bottom` is reapplied by SwiftUI on every layout pass that grows the
    /// content, which is how a running subagent is followed. A reader's own scroll replaces it with
    /// a point, and from then on nothing moves under them until they come back to the end.
    @State private var position = ScrollPosition(edge: .bottom)
    /// Whether the reader is at the end, at `ScrollEnd.threshold`, which is the test the chat uses
    /// to decide whether an arriving row may move the view.
    @State private var followsEnd = true
    /// The width the prompt's bubble may fill, computed the way the chat computes it. See
    /// `TranscriptBubbleWidth`.
    @State private var bubbleWidth = TranscriptBubbleWidth()
    /// Where a file chip's hover card is drawn, over the scroll view rather than inside a row that
    /// would clip it. See `TranscriptHoverHost`.
    @State private var hoverHost = TranscriptHoverHost()

    /// The conversation's text size, face and line height, read here for the reason `ChatPaneView`
    /// reads them: this pane is a conversation, and a reader who has set the transcript larger has
    /// not asked for a subagent's half of it to stay small.
    private var textSize: ChatTextSize { ColourThemePreference.shared.chatTextSize }
    private var chatFontID: String { ColourThemePreference.shared.chatFont }
    private var lineHeight: ChatLineHeight { ColourThemePreference.shared.chatLineHeight }

    /// The roster's account while it has one, and the call's own once it has not, which is the
    /// case of a finished subagent opened from the chat after the next turn started or after a
    /// relaunch.
    private var subagent: Subagent? {
        let roster = model.activeTranscript?.subagents
        switch target {
        case .live(let id):
            return roster?[id]
        case .recorded(let toolUseID):
            return roster?.subagent(forToolUseID: toolUseID)
                ?? model.recordedSubagent(forToolUseID: toolUseID)
        case .unavailable:
            return nil
        }
    }

    private var kind: SubagentKind { subagent?.kind ?? .agent }

    /// Where this subagent's paths point. The parent's worktree, because a subagent runs in it.
    private var home: TranscriptHome {
        model.activeTranscript?.home ?? TranscriptHome(model.workspace)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // The chat's opening space, so the header clears the fade at the top of the pane
                // exactly as a first bubble does there.
                Color.clear
                    .frame(height: TranscriptLayout.topSpace)
                    .accessibilityHidden(true)

                if let subagent {
                    header(subagent)
                        .subagentReadingColumn()

                    switch subagent.kind {
                    case .agent: agentBody(subagent)
                    case .command: commandBody(subagent)
                    }
                } else {
                    // Only reachable if the turn was cleared out from under the selection, which
                    // the next turn starting does by design.
                    Text(missingSentence)
                        .font(Typo.body)
                        .foregroundStyle(Palette.textSecondary)
                        .subagentReadingColumn()
                }
            }
            .padding(.bottom, Metrics.pane)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            ScrollEnd.isAtEnd(
                contentHeight: geometry.contentSize.height,
                viewportHeight: geometry.containerSize.height,
                offset: geometry.contentOffset.y
            )
        } action: { _, atEnd in
            followsEnd = atEnd
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            TranscriptGeometry.cap(
                width: proxy.size.width,
                share: TranscriptListView.bubbleShare,
                gutter: Metrics.gutter,
                floor: TranscriptListView.bubbleFloor
            )
        } action: { cap in
            // On a change only: the setter notifies on every assignment. See `TranscriptListView`.
            if bubbleWidth.cap != cap { bubbleWidth.cap = cap }
        }
        .overlay(alignment: .top) {
            // The chat's fade into the tab strip, for the chat's reason: text scrolling up was cut
            // off hard against it, a line sliced through its middle.
            LinearGradient(
                colors: [Palette.surface, Palette.surface.opacity(0)], startPoint: .top, endPoint: .bottom
            )
            .frame(height: TranscriptLayout.topFade)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .overlay { TranscriptHoverOverlay(host: hoverHost) }
        .background(Palette.surface)
        .environment(\.transcriptHoverHost, hoverHost)
        .environment(\.transcriptBubbleWidth, bubbleWidth)
        .environment(\.fontScale, textSize.scale)
        .environment(\.chatFont, ChatFont(rawValue: chatFontID))
        .environment(\.chatLineHeight, lineHeight)
        // What a link in a subagent's answer does when it is pressed, which is what it does in the
        // transcript: one rule for every address the window draws. See `TranscriptLink.actions`.
        .markdownLinkActions(TranscriptLink.actions(for: model))
        .onChange(of: reading) { _, _ in
            guard followsEnd else { return }
            position.scrollTo(edge: .bottom)
        }
        // A different subagent is a different conversation, opened at its end like the chat opens
        // one. Its opened rows and runs are its own, which the `id` on the conversation gives it.
        .onChange(of: target) { _, _ in
            isBriefExpanded = false
            followsEnd = true
            position.scrollTo(edge: .bottom)
        }
        // Re-read when the selection moves to a different subagent, and when this one ends. The
        // running case keeps re-reading inside the task rather than re-keying it: an id that
        // carried the elapsed seconds would tear the whole pane down and rebuild it once a second,
        // losing the scroll position and any row the reader had just opened.
        .task(id: "\(target):\(SubagentPane.refreshes(subagent))") { await follow() }
    }

    /// What the pane says when there is no subagent to describe at all.
    private var missingSentence: String {
        if case .recorded = target {
            // The call is not in the conversation that is open now: a different chat became the
            // active one after the row was clicked.
            return "That agent's run is not in the chat that is open now."
        }
        // Only reachable if the turn was cleared out from under the selection, which the next
        // turn starting does by design.
        return "That subagent belonged to a turn that has since been replaced."
    }

    /// Read the file, and keep reading it for as long as the task is running.
    private func follow() async {
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
        if case .live(let id) = target,
           let parsed = await model.activeTranscript?.codexSubagentTranscript(for: id) {
            guard !Task.isCancelled else { return }
            let updated = await Task.detached { SubagentReading(parsed) }.value
            guard !Task.isCancelled else { return }
            if updated != reading { reading = updated }
            failure = nil
            return
        }
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
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let parsed):
            // Compared first, because a write that changes nothing would still move the scroll
            // position to the end once a second under a reader who is at it.
            if parsed != reading { reading = parsed }
            failure = nil
        case .failure(let reason):
            if reading != SubagentReading() { reading = SubagentReading() }
            failure = reason
        }
    }

    /// The Task call this subagent hangs off, which is how its nested rows are found.
    private var toolUseID: String { subagent?.toolUseID ?? "" }

    // MARK: - Parts

    /// What it is and how long it has taken, set the way the chat sets a row: the mark in the
    /// glyph column, the title beside it, and the meta line under the title in the label face.
    private func header(_ subagent: Subagent) -> some View {
        VStack(alignment: .leading, spacing: TranscriptLayout.tight) {
            HStack(spacing: TranscriptLayout.glyphGap) {
                SubagentMarkGlyph(mark: SubagentRow(subagent).mark)
                    .frame(width: TranscriptLayout.glyphWidth)
                Text(SubagentRow.title(of: subagent))
                    .font(Typo.title)
                    .foregroundStyle(Palette.textPrimary)
                    .textSelection(.enabled)
            }

            Group {
                // Ticking while it runs, from the same clock the sidebar row counts on. Nothing
                // else in the pane changes once a second when the subagent is quiet, so without
                // this the duration stood still between rows.
                if subagent.state == .running {
                    TimelineView(.periodic(from: .now, by: SubagentPane.refreshSeconds)) { context in
                        Text(SubagentPane.subtitle(subagent, now: context.date))
                    }
                } else {
                    Text(SubagentPane.subtitle(subagent))
                }
            }
            .font(Typo.label)
            .foregroundStyle(Palette.textSecondary)
            .monospacedDigit()
            .padding(.leading, TranscriptLayout.glyphWidth + TranscriptLayout.glyphGap)

            // The CLI's one sentence, only where there is no conversation to read. Beside a
            // transcript it repeated the answer the transcript ends with.
            if !subagent.summary.isEmpty, reading.rows.isEmpty, reading.printed.isEmpty {
                Text(subagent.summary)
                    .font(Typo.body)
                    .textSelection(.enabled)
                    .padding(.top, TranscriptLayout.block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, TranscriptLayout.block)
    }

    /// An agent: its brief as the prompt, its rows as the chat draws them, its working line.
    @ViewBuilder
    private func agentBody(_ subagent: Subagent) -> some View {
        let isRunning = subagent.state == .running
        SubagentConversationView(
            rows: reading.rows,
            // `task_started` is the honest copy and it is gone with the turn that carried it, so
            // the one read back out of the transcript stands in for a pane opened after that.
            prompt: subagent.prompt.isEmpty ? reading.prompt : subagent.prompt,
            home: home,
            droppedRows: reading.droppedRows,
            isRunning: isRunning
        )
        .id(target)

        // A running subagent that has not spoken yet is covered by the working line above. Once
        // it has stopped, having nothing to read is worth a sentence.
        if let failure, !isRunning {
            Text(SubagentPane.nothingToShow(failure, kind: .agent, isRunning: false))
                .font(Typo.body)
                .foregroundStyle(Palette.textSecondary)
                .subagentReadingColumn()
        }
    }

    /// A background command: the line it ran and what it printed, both code.
    ///
    /// The command line arrives nowhere on the task's own lines, so it is lifted back out of the
    /// parent's Bash call: see `SubagentPane.commandLine`.
    @ViewBuilder
    private func commandBody(_ subagent: Subagent) -> some View {
        let command = model.commandLine(forToolUseID: subagent.toolUseID) ?? ""
        if !command.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                caption(SubagentPane.briefLabel(.command))
                if SubagentPane.briefCollapses(command) {
                    Button(TextFold.title(isExpanded: isBriefExpanded)) {
                        isBriefExpanded.toggle()
                    }
                    .linkButton()
                    .font(Typo.caption)
                }
                if !SubagentPane.briefCollapses(command) || isBriefExpanded {
                    DetailCodeBlock(text: command, copyTitle: "Copy the command")
                }
            }
            .padding(.bottom, TranscriptLayout.block)
            .subagentReadingColumn()
        }

        Group {
            if let failure {
                Text(SubagentPane.nothingToShow(
                    failure, kind: .command, isRunning: subagent.state == .running
                ))
                .font(Typo.body)
                .foregroundStyle(Palette.textSecondary)
            } else if !reading.printed.isEmpty {
                VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                    caption(SubagentPane.outputLabel(.command))
                    DetailCodeBlock(text: reading.printed, copyTitle: "Copy the output")
                }
            }
        }
        .subagentReadingColumn()
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
