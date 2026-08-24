import SwiftUI
import BloomCore

/// The sidebar's subagent rows, at the pane's real width, in every state a row can be in, and at
/// the three moments of a fan-out finishing.
///
/// The last three panes are a frame trace of the removal: the same eight subagents from the
/// screenshot that prompted it, at the instant they all finish, a second and a half later while
/// the ticks are still being held, and after the hold. `SubagentRetention` decides which of them
/// each pane draws and the suite pins every one of those decisions; this is what they look like.
///
/// Photographed in a real window rather than through `--snapshot`, for the reason
/// `RunningGlyphGallery` gives at length: the running mark is layer backed and an offscreen render
/// paints SwiftUI's yellow placeholder over any `NSViewRepresentable`, so `ImageRenderer` cannot
/// take a picture of a working row at all.
///
///     Bloom --snapshot-gallery <dir> --gallery subagent-rows --running
///
/// `--running` starts the heartbeat, since nothing is actually working in a capture.
struct SubagentRowGallery: View {
    /// The three subagents in `Tests/fixtures/claude-api-retry.ndjson`, mid turn.
    private var working: [Subagent] {
        [
            Subagent(id: SubagentID("1"), description: "Count lines in a.txt",
                     type: "general-purpose", outputFile: "/x", elapsedSeconds: 4),
            Subagent(id: SubagentID("2"), description: "Find Store.upsert call sites",
                     type: "Explore", outputFile: "/x", elapsedSeconds: 11),
            Subagent(id: SubagentID("3"), description: "Sketch the migration order",
                     type: "Plan", outputFile: "/x", elapsedSeconds: 9,
                     retry: AgentRetry(scope: .subagent(agentID: "3", toolUseID: nil, kind: nil),
                                       attempt: 2, maxAttempts: 10, delay: 1.1, status: 529)),
        ]
    }

    /// The same three, twenty seconds later. One worked, one worked, one was killed by the 529
    /// that was retrying above, and the last is a subagent the turn ended underneath.
    private var finished: [Subagent] {
        [
            Subagent(id: SubagentID("1"), description: "Count lines in a.txt",
                     type: "general-purpose", state: .completed, summary: "3 lines",
                     outputFile: "/x", elapsedSeconds: 6),
            Subagent(id: SubagentID("2"), description: "Find Store.upsert call sites",
                     type: "Explore", state: .completed, summary: "12 sites, listed below",
                     outputFile: "/x", elapsedSeconds: 14),
            Subagent(id: SubagentID("3"), description: "Sketch the migration order",
                     type: "Plan", state: .failed,
                     summary: "Agent terminated early due to an API error: API Error: 529 "
                        + "Overloaded.",
                     outputFile: "/x", elapsedSeconds: 21),
            Subagent(id: SubagentID("4"), description: "Read the release notes",
                     type: "general-purpose", state: .stopped, outputFile: "/x",
                     elapsedSeconds: 3),
        ]
    }

    /// A subagent that spawned subagents, drawn flat at the same indent. See `SubagentRow.rows`.
    private var deep: [Subagent] {
        [
            Subagent(id: SubagentID("5"), description: "Review the app layer", type: "Plan",
                     spawnDepth: 1, outputFile: "/x", elapsedSeconds: 30),
            Subagent(id: SubagentID("6"), description: "Read the views", type: "Explore",
                     spawnDepth: 2, outputFile: "/x", elapsedSeconds: 8),
            Subagent(id: SubagentID("7"), description: "Read one view", type: "Explore",
                     spawnDepth: 3, state: .completed, summary: "no findings", outputFile: "/x"),
        ]
    }

    /// A background command, which is not an agent at all and used to be drawn as one. See
    /// `SubagentKind`: a `local_bash` start carries a description and nothing else.
    private var command: [Subagent] {
        [
            Subagent(id: SubagentID("9"), description: "Build frontend assets",
                     taskType: "local_bash", elapsedSeconds: 12),
            Subagent(id: SubagentID("10"), description: "Push branch to origin",
                     taskType: "local_bash", state: .completed,
                     summary: "Background command completed (exit code 0)", elapsedSeconds: 3),
        ]
    }

    /// The screenshot that prompted the removal: seven ticks and a cross under one workspace that
    /// is still running.
    private var fanOut: [Subagent] {
        (1...8).map { index in
            Subagent(
                id: SubagentID("f\(index)"),
                description: [
                    "Read the app layer", "Read the core", "Read the tests", "Check the lint rules",
                    "Sketch the migration", "Count the call sites", "Read the release notes",
                    "Run the suite",
                ][index - 1],
                type: "Explore",
                state: index == 6 ? .failed : .completed,
                summary: index == 6 ? "Agent terminated early due to an API error" : "no findings",
                outputFile: "/x",
                elapsedSeconds: 4 + index,
                finishedAt: Self.finished
            )
        }
    }

    /// When the fan-out above ended, so the three trace panes can be asked for different moments.
    private static let finished = Date(timeIntervalSince1970: 1_700_000_000)

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 24) {
                pane("Mid turn", working)
                pane("Twenty seconds later", finished)
                pane("Depth past one, drawn flat", deep)
                pane("Not an agent at all", command)
            }
            HStack(alignment: .top, spacing: 24) {
                trace("The moment eight finish", after: 0)
                trace("1.5s, the ticks still held", after: 1.5)
                trace("After the hold", after: SubagentRetention.lingerSeconds + 0.1)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// One frame of the removal, at `after` seconds past the moment they all finished.
    private func trace(_ title: String, after seconds: Double) -> some View {
        pane(title, rows: SubagentRetention.rows(
            SubagentRoster(fanOut),
            now: Self.finished.addingTimeInterval(seconds)
        ), failures: SubagentRetention.failureCount(SubagentRoster(fanOut)))
    }

    /// The pane at its 260 point default, which is the only width these rows are ever judged at.
    private func pane(_ title: String, _ subagents: [Subagent]) -> some View {
        pane(title, rows: SubagentRow.rows(SubagentRoster(subagents)), failures: 0)
    }

    private func pane(_ title: String, rows: [SubagentRow], failures: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)

            VStack(alignment: .leading, spacing: 0) {
                workspaceRow(failures: failures)
                ForEach(rows) { row in
                    SubagentSidebarRow(row: row)
                        .frame(height: 32)
                }
            }
            .frame(width: 260, alignment: .leading)
            .background(Palette.surface)
        }
    }

    /// The workspace the children hang off, drawn the way the real pane draws it so the indents
    /// can be judged against each other.
    ///
    /// - Parameter failures: what is left on the row that PERSISTS when a subagent's own row goes.
    ///   A tick leaves nothing here; a cross leaves this, and so does every cross past the cap.
    private func workspaceRow(failures: Int) -> some View {
        Label {
            HStack(spacing: Metrics.spacingSmall) {
                Text("Review repository changes")
                    .font(Typo.caption)
                    .lineLimit(1)
                Spacer(minLength: Metrics.spacingSmall)
                if failures > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "xmark")
                        Text("\(failures)")
                    }
                    .font(Typo.micro)
                    .monospacedDigit()
                    .foregroundStyle(Palette.negative)
                }
            }
        } icon: {
            WorkspaceRunningGlyph()
        }
        .labelStyle(SidebarRowLabelStyle())
        .padding(.leading, SidebarMetrics.rowIndent)
        .frame(height: 32)
    }
}
