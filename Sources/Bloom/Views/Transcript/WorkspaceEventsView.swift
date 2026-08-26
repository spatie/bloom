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
struct WorkspaceEventsView: View, Equatable {
    /// The feed redraws when the workspace, the run or the pane changes, and not because the two
    /// closures beside them are new closures.
    ///
    /// Functions are never equal to one another, and both of these are built fresh in
    /// `TranscriptListView.body`, so without this SwiftUI had to assume the feed differed from the
    /// one it drew a moment ago and re-ran this body on every pass of the transcript's own list.
    /// That body reads the setup timeline, which is the whole of what the note above is about:
    /// the read was kept out of the list so a flush redraws these rows and nothing else, and a
    /// comparison that always fails put the list's passes back on top of it.
    ///
    /// **The transcript no longer needs it, and it is kept because the argument is still true of
    /// anything else that draws this.** A table rebuilds a cell only when its content key moves,
    /// so the feed is handed a fresh root view when the workspace, the run or the pane height
    /// changes and at no other time, which is the same set of conditions this compares. The list
    /// used to have to say `.equatable()` to get that; now it gets it for nothing.
    ///
    /// **The closures are ignored, and `workspaceID` is what makes that safe.** A view kept by an
    /// equal comparison keeps the closure it was built with, so what matters is what a stale one
    /// could still capture. Both close over `TranscriptListView` itself: its `@State` reaches
    /// through a storage box and is never stale, and the one stored value they reach, the
    /// transcript, cannot change without the workspace changing, which is compared here.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.workspaceID == rhs.workspaceID
            && lhs.isRunning == rhs.isRunning
            && lhs.isFirstThing == rhs.isFirstThing
            && lhs.paneHeight == rhs.paneHeight
    }

    var workspaceID: WorkspaceID
    /// Whether a setup run is in flight, as the pane above already knows it. The stored state
    /// catches up a moment later, when the workspace row is next read.
    var isRunning: Bool
    /// True while the session has no messages, which is the only time it is worth saying that a
    /// prompt typed now will go as soon as setup finishes.
    var isFirstThing: Bool
    /// How tall the transcript is, so a running setup can take a share of it rather than a fixed
    /// number of lines. Already quantised by `TranscriptGeometry.height`; nought means the pane has
    /// not been measured. See `SetupTailWindow`.
    var paneHeight: CGFloat = 0
    /// Told whether anything is drawn here, so the pane does not put an empty state over the top
    /// of it. Only this view can answer: it is the one that reads the log.
    var onVisibilityChange: (@MainActor (Bool) -> Void)?
    /// Asked to put the end of the setup log on screen: once when the reader unfolds the row, and
    /// again on every flush for as long as it stays unfolded and the script keeps printing.
    ///
    /// The expanded log is not a scroll view of its own: it grows the row, the row grows the
    /// transcript, and the transcript is therefore the only thing that can be moved to the end of
    /// a log. What that takes depends on what else is in the list, which is `TranscriptListView`'s
    /// business rather than this row's. See `WorkspaceEventRow.endID`.
    ///
    /// The flag says which of the two calls it is. They are answered differently: an unfold is the
    /// reader asking to be taken there, and is obeyed wherever they are; a flush is the log moving
    /// under them, and is obeyed only while they are still at the end of it.
    var onShowLogEnd: (@MainActor (Bool) -> Void)?

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
                WorkspaceEventRow(
                    event: event,
                    isFirstThing: isFirstThing,
                    paneHeight: paneHeight,
                    model: model,
                    onShowLogEnd: onShowLogEnd
                )
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
/// IS the message. The rest is behind the same disclosure a tool row uses.
///
/// **The row is where the log is read, and the link says so.** It used to say "Show the full log"
/// and open the Setup tab in the panel below. `a98e055` is why it did: the link had been setting a
/// tab that was already selected, so it did nothing at all, and pointing it at the panel and the
/// inspector by name was what made it move the window. That fixed the wrong half. A reader looking
/// at a failure in the transcript wants the rest of THAT, in the place they are already reading,
/// not their window rearranged around a second copy of it somewhere else. So the link now opens
/// the row, exactly as the caret beside it does, and its wording says which way it will go.
///
/// Both controls stay, and they can only ever say the same thing because they are the same piece
/// of state. The caret is where a disclosure lives on every other row in this transcript; the link
/// is what a reader who has just read twelve lines of a failure and wants more actually looks for,
/// at the bottom of those twelve lines rather than up on the header.
///
/// Since the panel at the bottom of the window went, this row is the only place a setup log is
/// read, which is why it unfolds to `TextCap.lineCap` lines where it used to stop at two hundred.
/// A failed run gets a second link beside the first, offering the run again, so that the sentence
/// the row already ends on ("run setup again") can be pressed where it is read rather than looked
/// for in the Workspace menu.
struct WorkspaceEventRow: View {
    var event: WorkspaceEvent
    var isFirstThing: Bool
    /// See `WorkspaceEventsView.paneHeight`, and `tailCap`.
    var paneHeight: CGFloat = 0
    var model: WorkspaceModel?
    /// See `endID`, and `WorkspaceEventsView.onShowLogEnd`.
    var onShowLogEnd: (@MainActor (Bool) -> Void)?

    @State private var isExpanded = false
    @State private var isHovered = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// What the conversation is set at, which is what a line of the tail is set at, and therefore
    /// what the window's fixed height is measured in. See `lineHeight`.
    @Environment(\.fontScale) private var fontScale

    /// The most lines of a running log this row may show, which is half the pane it is drawn in.
    ///
    /// It was a constant, five, and the reasoning for five is worth keeping because half of it is
    /// still doing the work. Three lines of a script that prints a line a second is three seconds
    /// of a window: a line is gone before it has been read. Five was also exactly the height this
    /// block already drew itself at whenever one of those three lines was long enough to wrap,
    /// which in a measured run of an ordinary setup script it was in two frames out of five,
    /// seventy nine points either way, so fixing it at five made the height ALWAYS that instead of
    /// sometimes. At the smallest window Bloom opens, the whole row was about a quarter of the
    /// transcript.
    ///
    /// What five could not do is answer "make setup bigger, it can take at least half of the chat
    /// screen", because that is a proportion and five is a number: it is a quarter of the smallest
    /// transcript and nearer a tenth of a large one, and the constant that gives half of a large
    /// window gives most of a laptop one. `SetupTailWindow` works it out from the pane's own
    /// height instead, with a floor for a pane squeezed by the terminal split and a ceiling so a
    /// full screen display does not hand over forty lines of `[====>----]`.
    ///
    /// Five survives inside it as `SetupTailWindow.settled`, which is the height the block holds
    /// from its first frame and never goes below, so the first seconds of every run are as still
    /// as they are today. See `SetupTailWindow.lines(cap:logLines:)`.
    private var tailCap: Int {
        SetupTailWindow.cap(paneHeight: Double(paneHeight), lineHeight: Double(lineHeight))
    }

    /// How many lines the running block is drawn at: the cap, or less while there is less log than
    /// that to put in it, never below the five it starts at. `SetupTailWindow.lines` is where the
    /// reasoning lives, and it is there rather than here because it is a decision.
    private var runningTail: Int {
        SetupTailWindow.lines(cap: tailCap, logLines: event.logLines)
    }

    /// A failure is read rather than glanced at, so it gets twelve lines, or the pane's own share
    /// where that is more. Never fewer than a running run in the same pane: a failure showing less
    /// of its log than a success would be the wrong way round in the one case where the log IS the
    /// message.
    private var failedTail: Int { SetupTailWindow.failureLines(cap: tailCap) }

    /// What the disclosure opens onto: the cap the transcript already puts on long output.
    ///
    /// Two hundred once, when opening the row was a preview and the whole log lived in the panel
    /// below. The row is now where a log is read, so it holds what any long tool result holds.
    /// `WorkspaceModel.setupLogLimit` keeps the log itself under two hundred thousand characters,
    /// which is inside `TextCap.characterCap`, so the line count is the only cap that binds here.
    private static let expandedTail = TextCap.lineCap

    var body: some View {
        // Read once for the pass. `tail` walks the log backwards from its end, and it was asked
        // for three times: here, to decide whether there is a block at all, and then again by the
        // block and by the text inside it.
        let tail = tail

        VStack(alignment: .leading, spacing: 0) {
            if canExpand {
                ExpandableRowHeader(isExpanded: isExpanded, onToggle: { isExpanded.toggle() }) {
                    header
                }
            } else {
                header
            }

            if !tail.isEmpty {
                logBlock(tail)
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

            // Under the sentence rather than under the log, so unfolding lands with the sentence
            // still on screen. Anchoring on the block itself put "You can ask for something now"
            // exactly one line below the bottom edge of the pane, which is the one line of this
            // row a reader who has never used Bloom before most needs.
            if event.kind == .setup {
                Color.clear.frame(height: 0).id(Self.endID)
            }
        }
        .modifier(ExpandableRow(isHovered: isHovered))
        .onHover { isHovered = $0 }
        .onChange(of: isExpanded) { _, isExpanded in
            guard isExpanded, event.kind == .setup else { return }
            showLogEnd(wasAsked: true)
        }
        // And again on every flush, so an unfolded log stays on its newest line rather than
        // growing off the bottom of the pane. Watched by byte count rather than by comparing the
        // text: the log runs to two hundred thousand characters, this fires several times a
        // second, and a native Swift string knows its own UTF-8 count without walking itself.
        //
        // Stops on its own when the script does, because a run that is no longer `.running` is
        // one the reader is reading rather than watching, and because nothing is arriving to
        // move anyway.
        .onChange(of: event.log.utf8.count) { _, _ in
            guard isExpanded, event.isRunning, event.kind == .setup else { return }
            showLogEnd(wasAsked: false)
        }
        .acceptsCaptureSetupLogExpansion {
            guard event.kind == .setup, canExpand else { return }
            isExpanded = true
        }
    }

    /// Where the setup row ends, which is where unfolding its log has to leave the reader.
    ///
    /// **The expanded log is not a scroll view of its own.** It is one `Text` that grows the row,
    /// and the row grows the transcript, so the transcript's scroller is the only thing that can
    /// move to the end of a log. That is worth keeping: a second scroller inside the pane would
    /// swallow the wheel for as long as the pointer was over it, and a reader could not get past
    /// a block that is five hundred lines tall.
    ///
    /// **Nothing reads this at the moment, and it is kept for what it knows rather than for what
    /// it does.** It was the id a `ScrollViewReader` was pointed at over the lazy stack, and the
    /// placement above is measured: under the sentence rather than under the log, because
    /// anchoring on the block put "You can ask for something now" exactly one line below the
    /// bottom edge of the pane.
    ///
    /// The table cannot be pointed at a SwiftUI id inside a cell. The whole feed is one row of the
    /// table, so `TranscriptListView.showSetupLogEnd` asks for the bottom of that row instead,
    /// which is the same place whenever the setup event is the last thing in the feed and is
    /// below it when something later has been added. Putting this back to work means measuring
    /// where this sentinel sits inside the row and scrolling to that offset, which is more
    /// machinery than the case has so far been worth.
    static let endID = "bloom.workspaceEvent.setupEnd"

    /// Puts the newest line of the log on screen.
    ///
    /// A beat later rather than in this pass. `onChange` runs before the row has been laid out at
    /// the height its unfolded log gives it, and a scroll resolved against the old layout lands
    /// short of the end by however many lines just appeared: measured at 293 points of travel
    /// where 301 was needed, which is half a line short of the newest one.
    private func showLogEnd(wasAsked: Bool) {
        Task { @MainActor in
            await Task.yield()
            onShowLogEnd?(wasAsked)
        }
    }

    private var header: some View {
        ToolRowHeader(
            presentation: event.presentation,
            // Only ever read by a file chip, and an event has none: its detail is a line of log or
            // a branch name, never a path this row invites anybody to open. It used to build an
            // empty `Workspace` with a blank `RepoID` every pass to satisfy the type.
            home: model.map { TranscriptHome($0.workspace) } ?? TranscriptHome(),
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
        case .running: return LogTail.last(event.log, lines: runningTail)
        case .failed: return LogTail.last(event.log, lines: failedTail)
        case .succeeded, .skipped: return ""
        }
    }

    /// The tail's own lines, drawn one `Text` each while the script is running so that the window
    /// moves instead of jumping.
    ///
    /// A running tail is a stated number of lines rather than as many as the text asks for, so
    /// nothing here is a scroll: the block stayed exactly where it was and its contents were
    /// replaced between one frame and the next, which is what "it just immediately shows next
    /// lines" was. Given each
    /// line an identity of its own, a line that is still in the window when the next one arrives
    /// is the same view moved to a new place, and SwiftUI slides it there.
    ///
    /// Only while it is running, and only while it is closed. A finished, failed or expanded tail
    /// is a fixed piece of text that is read rather than watched, and it stays one `Text`: that
    /// keeps a selection able to run across its lines, and keeps an expanded two hundred line log
    /// from becoming two hundred views. Those are also the three cases that may wrap: they are
    /// read, so nothing in them may be cut off, and none of them is moving while it is read.
    @ViewBuilder
    private func tailText(_ tail: String) -> some View {
        if event.isRunning, !isExpanded {
            // Once per pass rather than twice: the stack draws them and the settle below is keyed
            // on them, and working them out is a walk over the window and a walk over the log's
            // trailing newlines.
            let lines = SetupTailLine.lines(of: tail, endingAt: event.log)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    Text(line.text)
                        // One line on screen for one line of the log, whatever is in it. A line
                        // long enough to wrap counts as one line to `LogTail` and as two or three
                        // here, and that is what made this block change height as output went
                        // past it: measured at the pane's ordinary width, the window of three was
                        // forty eight points tall, then seventy nine, then forty eight again, and
                        // the sentence under it moved thirty one points every time. The whole of a
                        // cut line is a click away, behind the link below: an unfolded tail is one
                        // piece of text, and it wraps.
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
            //
            // `runningTail` is a whole number of lines of a known height, so this is still a
            // stated height and neither of those two movers can reach it. What it is no longer is
            // one number for every window: it is the pane's share, filled to the log where there
            // is less log than that, which is the only way a block that may be half the screen
            // does not sit there half empty. See `tailCap`. That number changes at most once per
            // line of real output and never once the log has passed the cap, it changes in step
            // with `lines`, and the settle below therefore carries the block's own growth as well
            // as the travel inside it: the block opens by a line as the line that fills it slides
            // in, over the same 0.12s.
            .frame(height: lineHeight * CGFloat(runningTail), alignment: .top)
            // So the departing line leaves the block rather than being drawn over the row above,
            // or over the link below, which is where it used to land.
            .clipped()
            .animation(reduceMotion ? nil : Self.settle, value: lines)
        } else {
            Text(marked(tail))
        }
    }

    /// The tail with only the failure in the alarm colour.
    ///
    /// A failed run used to be drawn entirely in `Palette.negative`, which told the reader that
    /// everything the script did had gone wrong. In the run this was written against, three of
    /// the seven lines are a Valet site being created, secured and served, and they worked. What
    /// failed is the `psql` line and the question indented underneath it, and `SetupLogLine` is
    /// what says which is which.
    ///
    /// One `AttributedString` rather than a `Text` per line, so a selection still runs across the
    /// whole block and an expanded log stays one view however long it is.
    private func marked(_ tail: String) -> AttributedString {
        guard event.isFailure, !event.failureSummary.isEmpty else { return AttributedString(tail) }

        var output = AttributedString()
        for line in SetupLogLine.lines(of: tail, failing: event.failureSummary) {
            if line.id > 0 { output += AttributedString("\n") }
            var run = AttributedString(line.text)
            if line.isFailure { run.foregroundColor = Palette.negative }
            output += run
        }
        return output
    }

    /// How tall one line of the tail is. See `SetupLineHeight`, which is where it is worked out
    /// and where it is held.
    private var lineHeight: CGFloat { SetupLineHeight.height(fontScale: fontScale) }

    /// One line of travel, and it is over before the next line is due.
    ///
    /// `WorkspaceModel` flushes what the script has printed every 120ms, so 0.12s is the longest
    /// this can take and still be finished when the fastest possible next line lands. A script
    /// printing a line every second gets a settle; one printing faster than the flusher gets a
    /// tail that reads as moving rather than one that stutters half a line behind itself. Ease
    /// out and no overshoot, which is the curve the panes already use.
    private static let settle: Animation = Motion.hover

    /// The same quoted block a tool result is drawn in, rule down the left and all, because it is
    /// the same thing: output from something that ran.
    private func logBlock(_ tail: String) -> some View {
        VStack(alignment: .leading, spacing: TranscriptLayout.tight) {
            tailText(tail)
                .font(Typo.code)
                // Every line starts as ordinary output. The failure colours itself, in `marked`,
                // and nothing else in the block is entitled to the alarm colour.
                .foregroundStyle(Palette.textSecondary)
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

            // Both links are about the same block of output, so they sit on one line under it
            // rather than stacking: one shows more of what happened, the other has another go at
            // it. The row draws nothing at all when neither applies, which is why the pair is
            // behind a condition of its own instead of being an `HStack` that is sometimes empty:
            // an empty stack is still a view, and the gap above it would be drawn under every
            // finished run.
            if showsExpandLink || showsRunSetupAgain {
                // Wider than the `spacing` rung most pairs use. These two are plain words in the
                // same size and the same accent colour, with nothing but the gap to say they are
                // two controls, and at six points "Show more of the log Run setup again" read as
                // one sentence somebody had forgotten to punctuate.
                HStack(spacing: Metrics.gutter) {
                    if showsExpandLink {
                        Button(isExpanded ? "Show less" : "Show more of the log") { isExpanded.toggle() }
                            .linkButton()
                            .font(Typo.caption)
                            .help(isExpanded ? "Folds the log back to its last lines" : "Unfolds the log in this row")
                            // The caret above this row is the same control, already announced as
                            // one by `ExpandableRowHeader` and already carrying the hint that says
                            // which way it will go. Two buttons that do one thing should be one
                            // thing to a reader who cannot see that they sit on the same row, so
                            // this half is the visible affordance and the caret is the spoken one.
                            .accessibilityHidden(true)
                    }

                    // Not hidden from accessibility the way its neighbour is. Nothing else on this
                    // row does what it does, so there is no second announcement of it to prefer.
                    if showsRunSetupAgain, let model {
                        Button("Run setup again") { SetupRunAlert.shared.ask(model) }
                            .linkButton()
                            .font(Typo.caption)
                            .help("Asks, then runs this repository's setup script in this workspace again")
                    }
                }
                .padding(.leading, TranscriptLayout.block)
            }
        }
        .padding(.leading, TranscriptLayout.detailIndent)
        .padding(.trailing, TranscriptLayout.inset)
        .padding(.bottom, TranscriptLayout.block)
    }

    /// Whether the link that unfolds the log is worth drawing. See `hasMoreToShow`.
    private var showsExpandLink: Bool {
        event.kind == .setup && canExpand && (isExpanded || hasMoreToShow)
    }

    /// Whether this row offers to run setup again.
    ///
    /// Only on a failure, because that is the row whose own advice ends in "run setup again" and
    /// the only one where a reader is looking for the way out. A run that finished is not offered
    /// a second one from here: the Workspace menu is where a re-run is asked for out of the blue,
    /// and this button is that menu item put where the failure is being read.
    ///
    /// `canRunSetup` answers both of the things that would make the offer a lie. A run already in
    /// flight fails it, so the button is gone for as long as one is going rather than sitting there
    /// inviting a second `composer install` into the same worktree, and by then the row has turned
    /// back into a running one with a moving tail anyway. A repository whose setup script has been
    /// deleted since the failure also fails it, since `WorkspaceModel.settings` is re-read whenever
    /// the workspace is selected. Should that cached answer ever be a moment stale,
    /// `WorkspaceManager.runSetup` re-reads the settings file itself and files the run as skipped
    /// with a line saying what it went looking for, so the worst case is an explanation rather than
    /// a wrong answer.
    private var showsRunSetupAgain: Bool {
        event.kind == .setup && event.outcome == .failed && model?.canRunSetup == true
    }

    /// Whether unfolding this row would actually show anything the reader cannot already see.
    ///
    /// A link offering more of a log that is four lines long is a link that does nothing, which is
    /// what this row already learned once: see the note on the button below. The closed row shows
    /// `failedTail` or `runningTail` lines depending on how the run ended, so the question is
    /// simply whether the log is longer than that.
    ///
    /// `tailCap` rather than `runningTail` on the running side, and the difference matters exactly
    /// while the block is still filling: `runningTail` is the log's own length there, so comparing
    /// against it would say there is more to show about a log that is entirely on screen, which is
    /// the dead link this note is about.
    private var hasMoreToShow: Bool {
        event.logLines > (event.isFailure ? failedTail : tailCap)
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

/// How tall one line of a setup log is, at the size the conversation is set to.
///
/// Asked of AppKit rather than written down, because it has to be the height SwiftUI actually lays
/// a line of this face out on: a number a point out is a window that clips its last line or leaves
/// a gap under it, and the conversation can be set at any size. `Typo.code` is the callout rung in
/// monospace, and `ScaledFont` rounds the scaled size to a whole point before asking for a face, so
/// both steps are repeated here. The same question `ComposerTextEditor` asks to size its own rows.
///
/// **Held rather than asked, because the row asks it per line per pass.** A running tail draws one
/// `Text` per line and states each one's height, the block states its own, and `tailCap` divides
/// the pane by it, so an `NSLayoutManager` was being allocated a dozen times per pass of a row that
/// redraws several times a second while a script runs. It is a pure function of the text size:
/// `fontScale` is the app's own setting, and the callout rung it multiplies does not move on macOS,
/// which has no Dynamic Type for it to track.
@MainActor
enum SetupLineHeight {
    private static var memo: (scale: CGFloat, height: CGFloat)?

    static func height(fontScale: CGFloat) -> CGFloat {
        if let memo, memo.scale == fontScale { return memo.height }

        let size = (NSFont.preferredFont(forTextStyle: .callout).pointSize * fontScale).rounded()
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let height = NSLayoutManager().defaultLineHeight(for: font)
        memo = (fontScale, height)
        return height
    }
}
