import SwiftUI
import BloomCore

/// The centre column while a subagent is selected: what that subagent was asked, what it did, and
/// what it answered.
///
/// **Everything else in the window keeps showing the parent workspace.** The terminal is still the
/// worktree's terminal, the diff is still the worktree's diff, the composer still sends to the
/// chat that spawned this. See `SidebarSelection.subagent`, which is where that decision lives:
/// it answers `workspaceID` with the parent, so every pane that hangs off the selection carries on
/// unchanged and this is the only one that had to notice.
///
/// **What it reads.** `system/task_notification.output_file`, which is the CLI's own transcript
/// for that subagent. It is a real file, written for a failed subagent as readily as for one that
/// worked (measured, not assumed: see `SubagentTranscript`), so the pane shows what the subagent
/// actually said rather than Bloom's reconstruction of it from the nested rows in the parent's
/// transcript. Bloom does not own the file, so every way of failing to read it is a sentence.
struct SubagentOutputView: View {
    var model: WorkspaceModel
    var subagentID: SubagentID

    @State private var transcript: SubagentTranscript?
    @State private var failure: SubagentOutput.Failure?

    private var subagent: Subagent? {
        model.activeTranscript?.subagents[subagentID]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.pane) {
                if let subagent {
                    header(subagent)
                    prompt(subagent)
                } else {
                    // Only reachable if the turn was cleared out from under the selection, which
                    // the next turn starting does by design.
                    Text("That subagent belonged to a turn that has since been replaced.")
                        .font(Typo.body)
                        .foregroundStyle(Palette.textSecondary)
                }

                if let failure {
                    Text(failure.sentence)
                        .font(Typo.body)
                        .foregroundStyle(Palette.textSecondary)
                } else if let transcript {
                    ForEach(transcript.entries.filter { $0.kind != .prompt }) { entry in
                        self.entry(entry)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Metrics.pane)
        }
        .background(Palette.windowBackground)
        // Re-read when the selection moves to a different subagent, and when this one ends: the
        // CLI writes the file as the subagent runs, so a pane opened mid run is showing a
        // prefix of it.
        .task(id: reloadKey) { await load() }
    }

    /// What a re-read is keyed to: which subagent, and whether it has finished. Not the elapsed
    /// seconds, which would re-read the file once a second for the whole of a long run.
    private var reloadKey: String {
        "\(subagentID.rawValue):\(subagent?.state.rawValue ?? "")"
    }

    private func load() async {
        // Off the main actor. A subagent's transcript is small in the capture and is not promised
        // to be: a fan-out that read files could leave a megabyte here.
        let path = subagent?.outputFile
        let result = await Task.detached { SubagentOutput.read(path: path) }.value
        switch result {
        case .success(let parsed):
            transcript = parsed
            failure = nil
        case .failure(let reason):
            transcript = nil
            failure = reason
        }
    }

    // MARK: - Parts

    private func header(_ subagent: Subagent) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            HStack(spacing: Metrics.spacingSmall) {
                SubagentMarkGlyph(mark: SubagentRow(subagent).mark)
                Text(SubagentRow.title(of: subagent))
                    .font(Typo.title)
            }

            Text(subtitle(subagent))
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

    /// The type, the depth when it is worth saying, and how long it took.
    private func subtitle(_ subagent: Subagent) -> String {
        var parts = [subagent.type.isEmpty ? "subagent" : subagent.type]
        // Only past one. Saying "depth 1" on every row would be noise on the case that is always
        // true, and the pane is the one place depth can be said at all: the sidebar draws every
        // depth at the same indent.
        if subagent.spawnDepth > 1 { parts.append("spawned by a subagent, depth \(subagent.spawnDepth)") }
        let elapsed = SubagentRow.duration(subagent.elapsedSeconds)
        if !elapsed.isEmpty { parts.append(elapsed) }
        return parts.joined(separator: " . ")
    }

    @ViewBuilder
    private func prompt(_ subagent: Subagent) -> some View {
        if !subagent.prompt.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                caption("Asked")
                Text(subagent.prompt)
                    .font(Typo.body)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func entry(_ entry: SubagentTranscript.Entry) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            caption(label(for: entry))
            Text(entry.body)
                .font(entry.kind == .text || entry.kind == .failure ? Typo.body : Typo.codeSmall)
                .foregroundStyle(colour(for: entry.kind))
                .textSelection(.enabled)
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
