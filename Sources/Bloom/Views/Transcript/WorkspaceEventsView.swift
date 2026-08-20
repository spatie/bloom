import SwiftUI
import AppKit
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
    /// The panel below is opened from here, so the link that says it will do that can. See
    /// `showFullLog`. Nothing in `body` reads it, so no row observes it and a setup that is
    /// flushing output several times a second does not invalidate on anything else the window
    /// does, exactly as in `ToolRowHeader`.
    @Environment(AppModel.self) private var app
    /// What the conversation is set at, which is what a line of the tail is set at, and therefore
    /// what the window's fixed height is measured in. See `lineHeight`.
    @Environment(\.fontScale) private var fontScale

    /// Enough to see that something is happening, and not so much that a build log pushes the
    /// conversation off the screen.
    ///
    /// Five rather than the three it was. Three lines of a script that prints a line a second is
    /// three seconds of a window: a line is gone before it has been read. Five is also exactly
    /// the height this block already drew itself at whenever one of those three lines was long
    /// enough to wrap, which in a measured run of an ordinary setup script it was in two frames
    /// out of five: seventy nine points either way. So nothing that fitted in the pane before
    /// stops fitting, and what changes is that it is that height ALWAYS instead of sometimes. At
    /// the smallest window Bloom opens, the whole row is about a quarter of the transcript.
    private static let runningTail = 5
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
        .modifier(ExpandableRow(isHovered: isHovered))
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
    /// A running tail is a fixed number of lines and never changes height, so nothing here is a
    /// scroll: the block stayed exactly where it was and its contents were replaced between one
    /// frame and the next, which is what "it just immediately shows next lines" was. Given each
    /// line an identity of its own, a line that is still in the window when the next one arrives
    /// is the same view moved to a new place, and SwiftUI slides it there.
    ///
    /// Only while it is running, and only while it is closed. A finished, failed or expanded tail
    /// is a fixed piece of text that is read rather than watched, and it stays one `Text`: that
    /// keeps a selection able to run across its lines, and keeps an expanded two hundred line log
    /// from becoming two hundred views. Those are also the three cases that may wrap: they are
    /// read, so nothing in them may be cut off, and none of them is moving while it is read.
    @ViewBuilder
    private var tailText: some View {
        if event.isRunning, !isExpanded {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    Text(line.text)
                        // One line on screen for one line of the log, whatever is in it. A line
                        // long enough to wrap counts as one line to `LogTail` and as two or three
                        // here, and that is what made this block change height as output went
                        // past it: measured at the pane's ordinary width, the window of three was
                        // forty eight points tall, then seventy nine, then forty eight again, and
                        // the sentence under it moved thirty one points every time. The rest of a
                        // cut line is a click away, in the panel the link below opens.
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // And a line is the same height whatever glyphs are in it, so a blank
                        // line or a line of dots takes the same room as a sentence.
                        .frame(height: lineHeight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // In at the bottom, out at the top, one line of travel each, which is the
                        // same line of travel the survivors between them are making. Every
                        // line in the block moves together and stays a line apart, so none of
                        // them is ever drawn across another. Fading an arrival into place instead
                        // put the new line under the one still sliding through it.
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        ))
                }
            }
            // The window, stated rather than left to the lines inside it. Two things move it
            // otherwise: a run that has printed fewer lines than the window holds, which used to
            // grow a line at a time through the first seconds of every setup, and the moment of
            // travel itself, where the departing line is still laid out and the stack is briefly
            // a line taller than it will end up. Top aligned, so a script's first lines start at
            // the top of the block and fill down, the way output does everywhere else.
            .frame(height: lineHeight * CGFloat(Self.runningTail), alignment: .top)
            // So the departing line leaves the block rather than being drawn over the row above,
            // or over the link below, which is where it used to land.
            .clipped()
            .animation(reduceMotion ? nil : Self.settle, value: lines)
        } else {
            Text(tail)
        }
    }

    private var lines: [SetupTailLine] {
        SetupTailLine.lines(of: tail, endingAt: event.log)
    }

    /// How tall one line of the tail is.
    ///
    /// Asked of AppKit rather than written down, because it has to be the height SwiftUI actually
    /// lays a line of this face out on: a number a point out is a window that clips its last line
    /// or leaves a gap under it, and the conversation can be set at any size. `Typo.code` is the
    /// callout rung in monospace, and `ScaledFont` rounds the scaled size to a whole point before
    /// asking for a face, so both steps are repeated here. The same question `ComposerTextEditor`
    /// asks to size its own rows.
    private var lineHeight: CGFloat {
        let size = (NSFont.preferredFont(forTextStyle: .callout).pointSize * fontScale).rounded()
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        return NSLayoutManager().defaultLineHeight(for: font)
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
                    // A quote mark, not a state: what failed is said by the text and by the word
                    // on the row above it.
                    Rectangle()
                        .fill(Palette.border)
                        .frame(width: TranscriptLayout.rule)
                }

            if event.kind == .setup, let model {
                Button("Show the full log") { showFullLog(model) }
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

    /// Opens the panel below onto this workspace's setup log.
    ///
    /// All three of these, and it used to be only the first. Selecting the tab on its own does
    /// nothing at all in the case the link is actually read in, which is a setup that is still
    /// running: `WorkspaceModel.runSetupThenSend` selects the Setup tab when it starts the
    /// script, so the click assigned the tab that was already selected and the window did not
    /// change by a pixel. That is what "clicking show the full log doesn't do anything" was. The
    /// chevron beside it worked because it toggles state this row draws itself from.
    ///
    /// The panel and the inspector are then asked for by name rather than left to `RootView`,
    /// which brings the inspector along when the panel's own switch CHANGES. An inspector closed
    /// over a panel that was already open is a real arrangement, and there the follow-on never
    /// fires and the link would still have opened nothing.
    private func showFullLog(_ model: WorkspaceModel) {
        model.bottomTab = .setup
        app.isInspectorVisible = true
        app.isBottomPanelVisible = true
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
