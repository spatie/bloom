import SwiftUI
import BloomCore

/// What Bloom did to this workspace, at the top of its transcript.
///
/// The feed, and the decision about whether there is anything in it at all. Reading the model
/// happens here rather than in `TranscriptListView`, and that is a performance decision as much as
/// a tidy one: a setup script flushes new output several times a second, and if the list's own body
/// read it, every flush would re-run the `ForEach` over every row in the session. Nothing above
/// this view reads the log, so a running setup redraws these rows and nothing else.
struct WorkspaceEventsView: View {
    var workspaceID: String
    /// Whether a setup run is in flight, as the pane above already knows it. The stored state
    /// catches up a moment later, when the workspace row is next read.
    var isRunning: Bool
    /// True while the session has no messages, which is the only time it is worth saying that a
    /// prompt typed now will go as soon as setup finishes.
    var isFirstThing: Bool
    /// Told whether anything is drawn here, so the pane does not put an empty state over the top
    /// of it. Only this view can answer: it is the one that reads the log.
    var onVisibilityChange: (@MainActor (Bool) -> Void)?

    @Environment(AppModel.self) private var app

    private var model: WorkspaceModel? { app.existingModel(for: workspaceID) }

    private var events: [WorkspaceEvent] {
        guard let model else { return [] }
        return model.timeline(isRunningSetup: isRunning)
    }

    var body: some View {
        let events = events

        // A `Group` rather than a bare `if`, so the visibility report has a view to hang on in
        // both cases. On the empty branch there would otherwise be nothing to run an `onChange`
        // on, and the pane would never be told it may draw its empty state again.
        Group {
            ForEach(events) { event in
                WorkspaceEventRow(event: event, isFirstThing: isFirstThing, model: model)
            }
        }
        .onChange(of: events.isEmpty, initial: true) { _, isEmpty in
            onVisibilityChange?(!isEmpty)
        }
    }
}

/// One thing Bloom did, on the transcript's columns.
///
/// Quiet by default, which is the rule for everything in this list: a finished setup and a merge
/// are one line each. A run in flight shows a few lines of its tail so that something is moving,
/// and a failure shows more of it without being asked, because a failure is the case where the log
/// IS the message. Everything else is behind the same disclosure a tool row uses, and the whole log
/// is one click further on, in the tab that has a scroller for it.
struct WorkspaceEventRow: View {
    var event: WorkspaceEvent
    var isFirstThing: Bool
    var model: WorkspaceModel?

    @State private var isExpanded = false
    @State private var isHovered = false

    /// Enough to see that something is happening, and not so much that a build log pushes the
    /// conversation off the screen.
    private static let runningTail = 3
    /// A failure is read rather than glanced at.
    private static let failedTail = 12
    /// What the disclosure opens onto. The rest stays in the panel below.
    private static let expandedTail = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if canExpand {
                ExpandableRowHeader(isExpanded: isExpanded, onToggle: { isExpanded.toggle() }) {
                    header
                }
            } else {
                header
            }

            if !tail.isEmpty {
                logBlock
            }

            if !note.isEmpty {
                Text(note)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, TranscriptLayout.detailIndent)
                    .padding(.trailing, TranscriptLayout.inset)
                    .padding(.bottom, TranscriptLayout.block)
            }
        }
        .modifier(ExpandableRow(isHovered: isHovered, isError: event.isFailure))
        .onHover { isHovered = $0 }
    }

    private var header: some View {
        ToolRowHeader(
            presentation: event.presentation,
            // Only ever read by a file chip, and an event has none: its detail is a line of log or
            // a branch name, never a path this row invites anybody to open.
            workspace: model?.workspace ?? Workspace(repoID: "", name: "", branch: "", path: "", baseBranch: ""),
            isError: event.isFailure,
            durationMS: event.durationMS,
            isExpanded: isExpanded,
            isHovered: isHovered
        )
    }

    /// Only where there is something behind the disclosure. A merge has no log, and a chevron that
    /// opens onto nothing is worse than no chevron.
    private var canExpand: Bool { !event.log.isEmpty }

    private var note: String {
        if event.isRunning, isFirstThing, event.kind == .setup {
            return "You can ask for something now. It goes as soon as setup finishes."
        }
        return event.note
    }

    private var tail: String {
        guard !event.log.isEmpty else { return "" }
        if isExpanded { return LogTail.last(event.log, lines: Self.expandedTail) }

        switch event.outcome {
        case .running: return LogTail.last(event.log, lines: Self.runningTail)
        case .failed: return LogTail.last(event.log, lines: Self.failedTail)
        case .succeeded, .partial, .skipped: return ""
        }
    }

    /// The same quoted block a tool result is drawn in, rule down the left and all, because it is
    /// the same thing: output from something that ran.
    private var logBlock: some View {
        VStack(alignment: .leading, spacing: TranscriptLayout.tight) {
            Text(tail)
                .font(Typo.code)
                .foregroundStyle(event.isFailure ? Palette.negative : Palette.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, TranscriptLayout.block)
                .padding(.vertical, TranscriptLayout.tight)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(event.isFailure ? Palette.negative : Palette.border)
                        .frame(width: TranscriptLayout.rule)
                }

            if event.kind == .setup, let model {
                Button("Show the full log") { model.bottomTab = .setup }
                    .buttonStyle(.link)
                    .font(Typo.caption)
                    .padding(.leading, TranscriptLayout.block)
                    // Not "the Setup tab", which is only in the strip while the repository has
                    // a setup script configured. The panel shows the log either way.
                    .help("Opens the whole log in the panel below")
            }
        }
        .padding(.leading, TranscriptLayout.detailIndent)
        .padding(.trailing, TranscriptLayout.inset)
        .padding(.bottom, TranscriptLayout.block)
    }
}
