import SwiftUI
import BloomCore

/// The sidebar's subagent rows, at the pane's real width, in every state a row can be in.
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

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            pane("Mid turn", working)
            pane("Twenty seconds later", finished)
            pane("Depth past one, drawn flat", deep)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The pane at its 260 point default, which is the only width these rows are ever judged at.
    private func pane(_ title: String, _ subagents: [Subagent]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)

            VStack(alignment: .leading, spacing: 0) {
                workspaceRow
                ForEach(SubagentRow.rows(SubagentRoster(subagents))) { row in
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
    private var workspaceRow: some View {
        Label {
            Text("Review PR 168")
                .font(Typo.caption)
        } icon: {
            WorkspaceRunningGlyph()
        }
        .labelStyle(SidebarRowLabelStyle())
        .padding(.leading, SidebarMetrics.rowIndent)
        .frame(height: 32)
    }
}
