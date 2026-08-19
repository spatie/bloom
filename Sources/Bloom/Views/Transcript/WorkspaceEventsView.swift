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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    /// The tail's own lines, drawn one `Text` each while the script is running so that the window
    /// moves instead of jumping.
    ///
    /// A running tail is three lines wide and never changes height, so nothing here is a scroll:
    /// the block stayed exactly where it was and its contents were replaced between one frame and
    /// the next, which is what "it just immediately shows next lines" was. Given each line an
    /// identity of its own, a line that is still in the window when the next one arrives is the
    /// same view moved to a new place, and SwiftUI slides it there.
    ///
    /// Only while it is running, and only while it is closed. A finished, failed or expanded tail
    /// is a fixed piece of text that is read rather than watched, and it stays one `Text`: that
    /// keeps a selection able to run across its lines, and keeps an expanded two hundred line log
    /// from becoming two hundred views.
    @ViewBuilder
    private var tailText: some View {
        if event.isRunning, !isExpanded {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    Text(line.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // In at the bottom, out at the top, one line of travel each, which is the
                        // same line of travel the two survivors between them are making. Every
                        // line in the block moves together and stays a line apart, so none of
                        // them is ever drawn across another. Fading an arrival into place instead
                        // put the new line under the one still sliding through it.
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        ))
                }
            }
            // So the departing line leaves the block rather than being drawn over the row above.
            .clipped()
            .animation(reduceMotion ? nil : Self.settle, value: lines)
        } else {
            Text(tail)
        }
    }

    private var lines: [SetupTailLine] {
        SetupTailLine.lines(of: tail, endingAt: event.log)
    }

    /// One line of travel, and it is over before the next line is due.
    ///
    /// `WorkspaceModel` flushes what the script has printed every 120ms, so 0.12s is the longest
    /// this can take and still be finished when the fastest possible next line lands. A script
    /// printing a line every second gets a settle; one printing faster than the flusher gets a
    /// tail that reads as moving rather than one that stutters half a line behind itself. Ease
    /// out and no overshoot, which is the curve the panes already use.
    private static let settle: Animation = .easeOut(duration: 0.12)

    /// The same quoted block a tool result is drawn in, rule down the left and all, because it is
    /// the same thing: output from something that ran.
    private var logBlock: some View {
        VStack(alignment: .leading, spacing: TranscriptLayout.tight) {
            tailText
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

/// One line of a running log's tail, with an identity that survives the window moving past it.
///
/// The identity is where the line starts, counted in UTF-8 bytes from the start of the log. That
/// is the one thing about a line that does not change as more output arrives, and it is what lets
/// SwiftUI recognise the line it drew a moment ago in the row below and move it up rather than
/// draw a second one. The line's own text will not do: a log repeats itself constantly, and two
/// identical `bun install` lines in one window would be one view.
///
/// It costs nothing to work out. A native Swift string knows its own UTF-8 count without walking
/// itself, and everything else here is measured over the three lines being drawn rather than over
/// the log, which runs to two hundred thousand characters.
///
/// Past that cap `WorkspaceModel.appendSetupOutput` drops text off the front, every offset shifts,
/// and the window crossfades instead of sliding. That is the right way round: a script that has
/// printed two hundred thousand characters is going faster than a reader follows a line at a time
/// anyway, and it is the same fallback a batch of a dozen lines arriving in one flush already
/// gets, since it shares no line with the window it replaces.
struct SetupTailLine: Identifiable, Equatable {
    var id: Int
    var text: String

    /// The lines of `tail`, which must be the end of `log` as `LogTail.last` returns it.
    static func lines(of tail: String, endingAt log: String) -> [SetupTailLine] {
        guard !tail.isEmpty else { return [] }

        // `LogTail.last` drops the newlines the log ends with, so what lies between the end of the
        // window and the end of the log is exactly those, and counting them back is what puts the
        // window's first line at its true offset.
        var trailing = 0
        var index = log.endIndex
        while index > log.startIndex {
            let previous = log.index(before: index)
            guard log[previous].isNewline else { break }
            trailing += log[previous].utf8.count
            index = previous
        }

        var start = log.utf8.count - tail.utf8.count - trailing
        var result: [SetupTailLine] = []
        var text = ""

        // Walked by character rather than split on "\n", so a script that ends its lines with a
        // carriage return breaks into the same lines `LogTail` counted, and so a "\r\n" is charged
        // the two bytes it takes rather than one.
        for character in tail {
            if character.isNewline {
                result.append(SetupTailLine(id: start, text: text))
                start += text.utf8.count + character.utf8.count
                text = ""
            } else {
                text.append(character)
            }
        }
        result.append(SetupTailLine(id: start, text: text))
        return result
    }
}
