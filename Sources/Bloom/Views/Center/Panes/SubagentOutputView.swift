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
/// `SubagentTranscript.live(streamLines:)` and `WorkspaceModel.subagentStreamLines(forToolUseID:)`.
///
/// **It stays live while the subagent works**, which is the case it is most often opened in. The
/// brief is known the moment the task starts, so it is on screen immediately; the output file
/// grows under the CLI's hand, so it is re-read on `SubagentPane.refreshSeconds`. The version
/// before this keyed its one read on the subagent's state, so a pane opened mid run showed
/// whatever prefix existed at the instant it was opened and then nothing more until the end.
///
/// Everything decided is decided in `SubagentPane`, `SubagentKind` and `SubagentTranscript`.
struct SubagentOutputView: View {
    var model: WorkspaceModel
    var subagentID: SubagentID

    @State private var transcript: SubagentTranscript?
    @State private var failure: SubagentOutput.Failure?
    @State private var isBriefExpanded = false

    private var subagent: Subagent? {
        model.activeTranscript?.subagents[subagentID]
    }

    private var kind: SubagentKind { subagent?.kind ?? .agent }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.pane) {
                if let subagent {
                    header(subagent)
                    brief(subagent)
                } else {
                    // Only reachable if the turn was cleared out from under the selection, which
                    // the next turn starting does by design.
                    Text("That subagent belonged to a turn that has since been replaced.")
                        .font(Typo.body)
                        .foregroundStyle(Palette.textSecondary)
                }

                output
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Metrics.pane)
        }
        .background(Palette.windowBackground)
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
        // to be, and this now runs once a second rather than once.
        let path = subagent?.outputFile
        let kind = kind
        // Read on the main actor, parsed off it. These are rows the transcript owns.
        let lines = kind == .agent ? model.subagentStreamLines(forToolUseID: toolUseID) : []
        let result = await Task.detached {
            switch SubagentOutput.read(path: path, kind: kind) {
            case .success(let parsed):
                return Result<SubagentTranscript, SubagentOutput.Failure>.success(parsed)
            case .failure(let reason):
                // **What Bloom saw, when the CLI has not written anything to read.** This is the
                // whole of a running subagent's pane: the file is named on the line that ends it,
                // so for the length of the run the read above can only fail. Falling back rather
                // than replacing, because once the file is there it is the CLI's own record of
                // the task and this is a copy of what went past. See
                // `SubagentTranscript.live(streamLines:)`.
                let live = SubagentTranscript.live(streamLines: lines)
                return live.isEmpty ? .failure(reason) : .success(live)
            }
        }.value
        switch result {
        case .success(let parsed):
            transcript = parsed
            failure = nil
        case .failure(let reason):
            transcript = nil
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
    }

    /// What it was given to do: a prompt for an agent, a command line for a background command.
    ///
    /// The prompt arrives on `task_started` and is therefore on screen from the first frame, which
    /// is the half of this that is useful before the task has finished. A command line arrives
    /// nowhere on the task's own lines, so it is lifted back out of the parent's Bash call: see
    /// `SubagentPane.commandLine`.
    @ViewBuilder
    private func brief(_ subagent: Subagent) -> some View {
        let text = briefText(subagent)
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                caption(SubagentPane.briefLabel(subagent.kind))
                Text(isBriefExpanded ? text : SubagentPane.briefHead(text))
                    .font(SubagentPane.briefIsCode(subagent.kind) ? Typo.codeSmall : Typo.body)
                    .textSelection(.enabled)
                if SubagentPane.briefCollapses(text) {
                    Button(TextFold.title(isExpanded: isBriefExpanded)) {
                        isBriefExpanded.toggle()
                    }
                    .buttonStyle(.link)
                    .font(Typo.caption)
                }
            }
        }
    }

    private func briefText(_ subagent: Subagent) -> String {
        switch subagent.kind {
        case .agent: subagent.prompt
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
        } else if let transcript {
            if transcript.droppedEntries > 0 {
                caption("\(transcript.droppedEntries) earlier steps not shown")
            }
            // `.prompt` is dropped: it is the same text the brief above already shows in full,
            // and showing it twice would push the answer another screen down.
            ForEach(transcript.entries.filter { $0.kind != .prompt }) { entry in
                self.entry(entry)
            }
        }
    }

    @ViewBuilder
    private func entry(_ entry: SubagentTranscript.Entry) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            caption(label(for: entry))
            Text(entry.body)
                .font(Self.isProse(entry.kind) ? Typo.body : Typo.codeSmall)
                .foregroundStyle(colour(for: entry.kind))
                .textSelection(.enabled)
        }
    }

    /// Which entries are somebody's words and which are a machine's. The standing rule: monospace
    /// is for what a machine said or will run, and what a model wrote in English is not that.
    static func isProse(_ kind: SubagentTranscript.Entry.Kind) -> Bool {
        switch kind {
        case .text, .failure, .thinking, .prompt: true
        case .tool, .toolResult, .printed: false
        }
    }

    private func label(for entry: SubagentTranscript.Entry) -> String {
        switch entry.kind {
        case .prompt: "Asked"
        case .text: "Answered"
        case .thinking: "Thought"
        case .tool: entry.title.isEmpty ? "Called a tool" : entry.title
        case .toolResult: "Result"
        case .failure: "Stopped"
        case .printed: SubagentPane.outputLabel(.command)
        }
    }

    private func colour(for kind: SubagentTranscript.Entry.Kind) -> Color {
        switch kind {
        case .failure: Palette.negative
        case .thinking, .toolResult: Palette.textSecondary
        default: Palette.textPrimary
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Typo.micro)
            .tracking(Typo.microTracking)
            .foregroundStyle(Palette.textTertiary)
    }
}
