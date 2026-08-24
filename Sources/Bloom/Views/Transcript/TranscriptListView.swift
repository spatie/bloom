import SwiftUI
import BloomCore

/// Every row of a session, and the rules for where the view sits among them.
///
/// It is a `ScrollView` over a `LazyVStack` rather than a `List` for one reason, which is that a
/// session can hold tens of thousands of rows and a `List` insists on knowing about all of them.
/// Here nothing is decoded, measured or styled until it is about to be on screen.
struct TranscriptListView: View {
    let transcript: TranscriptModel
    /// Only to explain an empty transcript: a workspace whose setup script is still running has a
    /// session but cannot have said anything yet.
    var isRunningSetup: Bool = false
    /// Where this pane's place in this conversation is kept while the pane does not exist. Nil for
    /// a transcript nobody comes back to, which is the archive sheet's. See `TranscriptResume`.
    let memory: TranscriptPaneMemory?
    let onScrolledUpChange: (@MainActor @Sendable (Bool) -> Void)?

    init(
        transcript: TranscriptModel,
        isRunningSetup: Bool = false,
        memory: TranscriptPaneMemory? = nil,
        onScrolledUpChange: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        self.transcript = transcript
        self.isRunningSetup = isRunningSetup
        self.memory = memory
        self.onScrolledUpChange = onScrolledUpChange
        // Seeded here rather than restored from a `task`, because both of these decide what the
        // FIRST pass of this body draws and a task runs after it. `remembered` reads a dictionary
        // that is `@ObservationIgnored`, so asking costs nothing and subscribes to nothing.
        let remembered = memory?.remembered(session: transcript.session.id)
        _expanded = State(initialValue: remembered?.expanded ?? [])
        _drawnInFull = State(
            initialValue: TranscriptResume.drawsInFull(remembered) ? transcript.session.id : nil
        )
        _owesHistory = State(initialValue: TranscriptResume.opensOnTheTail(remembered))
    }

    /// Which tool results are unfolded.
    ///
    /// It used to say that expansion is a property of this view and not of the session, and the
    /// second half of that is still true: the model has no business knowing what is unfolded, and
    /// reopening a workspace should not restore forty open tool results. The first half was the
    /// bug. This view is destroyed and rebuilt by every tab switch, so an unfolded result silently
    /// re-folded every time the reader looked at the changes and came back. It is seeded from, and
    /// written to, the pane's own memory, which lasts as long as the launch and no longer.
    @State private var expanded: Set<Int> = []
    @State private var geometry = TranscriptGeometry()
    @State private var didPosition = false

    /// The chip or the row the pointer is resting on, shared with every row in the list.
    ///
    /// Held here because the card has to be drawn here: a card next to a chip inside the lazy
    /// stack is clipped by the pane. Only `TranscriptHoverOverlay` reads it, so a hover never
    /// re-runs this body. See `TranscriptHoverHost`.
    @State private var hoverHost = TranscriptHoverHost()

    /// Two things, and the comment used to claim one.
    ///
    /// `linkActions` reaches the workspace's model, which is what a link opened in a browser tab
    /// needs, and `existingModel` reads nothing observable to answer. `visibleRows` reads
    /// `pendingTranscriptTarget`, and that one is a real subscription: this body runs again when
    /// a transcript search sets it and again when the arrival clears it. It stays, because it is
    /// what keeps a session that was opened on a searched row from drawing a tail the row is not
    /// in, and two passes per search is not a cost worth moving anything for. What must not
    /// appear here is a read of anything that moves while a turn runs.
    @Environment(AppModel.self) private var app

    /// Every programmatic move to the live end goes through this: opening a session on its end,
    /// the jump pill, history arriving, and the setup log's reveal. An edge needs no identity,
    /// so none of them needs the sentinel row the `ScrollViewReader` used to be pointed at.
    @State private var scrollPosition = ScrollPosition(edge: .bottom)

    /// Which rows have only just turned up, so they fade in rather than appear at full opacity in
    /// a single frame. The rules for what counts as "just turned up" are `RowArrival`'s, which is
    /// the same mechanism and the same settle the sidebar and Home give their rows.
    ///
    /// Keyed on the sequence number itself rather than on a string of it. A row now asks the
    /// tracker a question on every pass rather than only when the tracker has something to say
    /// (see `isArriving`), and a question asked that often must not allocate to be asked.
    @State private var arrival = RowArrival<Int>()

    /// The scroll view a glide to the live end is driven through, and the travel along it.
    ///
    /// See `TranscriptLiveEndScroller`, which carries the frame timings that put an AppKit level
    /// scroll there in place of the `withAnimation` this used to be one line of.
    @State private var scroller = TranscriptLiveEndScroller()

    /// What keeps the view with the newest row while a turn runs, and turns the last of that
    /// travel into something the eye can follow. See `TranscriptLiveEndFollower`, which is where
    /// the rules about whose view it may move are, and `TranscriptFollow`, where the arithmetic
    /// is. Nothing in this body reads it, on purpose: it writes no SwiftUI state, so following a
    /// turn costs no pass over this list.
    @State private var follower = TranscriptLiveEndFollower()

    /// Whether this window is the one in front, which is the whole of what the follower needs it
    /// for: a display link in a backgrounded app is the battery cost `ActivityDot` carries the
    /// measurement for, and there is nobody watching the travel.
    @Environment(\.controlActiveState) private var activeState

    /// The unanimated second half of a glide to the live end, if one is owed. See `goToLiveEnd`.
    @State private var catchUp: Task<Void, Never>?

    /// Read here rather than inside `TranscriptMotion`, which is in a target that has never heard
    /// of AppKit. The core decides what the setting means and the view is where the setting is.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The session the tracker above is following.
    ///
    /// Nothing fades until a session has finished arriving. Switching workspaces hands this list
    /// eighty rows in one frame and the rest of the history a beat later, and neither is work
    /// turning up in front of the reader: it is the pane being pointed somewhere else. See
    /// `trackArrivals` and the `task` below, which is where a session stops arriving.
    @State private var arrivalSession: SessionID?

    /// Where this session was opened, so the reveal can put it back there once the history has
    /// landed under it. See `position` and the reveal in `task`.
    ///
    /// Three openings and only one of them is the live end: a session opened on an unread mark or
    /// on a row somebody searched for was opened where the reader asked to be, and putting it back
    /// means putting it back THERE. The reveal used to say the live end whatever had been chosen,
    /// which was wrong for two of the three and did nothing at all for the third.
    private enum Opening: Equatable {
        case liveEnd
        /// A row, and where in the pane it was put.
        case row(Int, UnitPoint)
        /// A number of points down the content, which only a pane coming back to a session it has
        /// already drawn ever has. See `TranscriptResume`.
        case offset(Double)
    }

    @State private var opening: Opening?

    /// Where the scroll view is now, so that leaving the pane can write it down.
    ///
    /// In a box rather than in `@State` for the reason `GeometryBox` sets out: this is written on
    /// every frame of every scroll, and as `@State` every one of those frames would re-run this
    /// body and with it every realised row, to store a number the body never reads. It is
    /// deliberately not folded into `TranscriptGeometry` either: every value in there is quantised
    /// so that a drag stops writing state, and a raw offset would undo that for all of them.
    @State private var contentOffset = GeometryBox(0.0)

    /// The text scale the rows are being drawn at, read for one thing: an offset written down at
    /// one size is a point into a document laid out at another. See `TranscriptPaneState.Measure`.
    @Environment(\.fontScale) private var fontScale

    /// The session whose history has been put back, if any. See `visibleRows`.
    ///
    /// A session id rather than a flag, because this view is the same view in the same place for
    /// every workspace the window visits, and a flag left standing from the last one would draw
    /// the next one's whole history onto the frame that is trying to arrive.
    @State private var drawnInFull: SessionID?

    /// Whether this pane came back to the end of a session it has drawn before, so it is holding a
    /// tail and owes the history behind it only if the reader goes looking for it.
    ///
    /// False for a first open, which also draws a tail but owes its history on the hundred
    /// millisecond timer that has always put it there: an unread mark or a searched row can be
    /// anywhere in the session and a reader arriving has to be able to reach them. See
    /// `TranscriptResume.opensOnTheTail`.
    @State private var owesHistory = false

    /// Set for the one layout pass that puts the history back underneath the reader, and read by
    /// the size-change anchor.
    ///
    /// **The anchor is what stops that layout being a jump.** Content grows above the viewport by
    /// however tall the history is, and `.bottom` holds the bottom edge still while it does, so
    /// what is on screen stays exactly where it is. It cannot simply be the anchor's standing
    /// value, which is `geometry.isNearBottom`: `.bottom` while the reader is scrolled up is the
    /// live end dragging them back down as a turn streams, which is the one thing this list must
    /// never do. So it is a flag for the single pass that needs it, set with `drawnInFull` and
    /// dropped as soon as the growth has landed.
    @State private var isRevealingHistory = false

    /// Sentinel id, negative so it can never collide with a row sequence number.
    private static let streamingID = -2
    /// The same, for the bubble drawn while a message is on its way to the agent. Its own id so
    /// that the stored row taking its place is an id the list has not seen, which is what makes
    /// the swap a replacement rather than a row changing under the reader.
    private static let sendingID = -3

    /// A pending message's id in the list.
    ///
    /// A string rather than an integer, which is what every row id here is, so a delivery can
    /// never be mistaken for a sequence number however the two lists grow. The same trick
    /// `WorkspaceEventRow.endID` uses and for the same reason.
    private static func pendingID(_ id: DeliveryID) -> String { "bloom.pending.\(id)" }
    /// A user bubble takes this share of the pane, and never gets narrower than the floor, so a
    /// long prompt wraps sensibly and a short one still reads as one side of a conversation.
    private static let bubbleShare: CGFloat = 0.7
    private static let bubbleFloor: CGFloat = 240

    /// How many rows at the live end the arrival tracker is shown.
    ///
    /// The set difference only ever has to see the end of the list: rows are appended and never
    /// reordered, so an id that falls out of this window cannot come back and be mistaken for
    /// something new. Handing it a four thousand row session instead would build four thousand
    /// strings every time one row lands.
    private static let arrivalWindow = 200

    /// Whether the workspace event rows are drawing anything, reported by them because only they
    /// can see the log. See `showsPlaceholder`.
    @State private var showsSetup = false

    /// Only once the rows are known to be absent, so a session that is still loading does not flash
    /// an empty state on its way in.
    ///
    /// And not while setup is showing. A workspace whose setup is still running, or whose setup
    /// failed before the agent was ever started, has an empty session and something worth reading
    /// at the top of it, and an empty state centred over the pane would be drawn straight across
    /// it. The old "the setup script is still running" wording lives in `TranscriptPlaceholderView`
    /// and is now the fallback for the moment before the first line of output arrives rather than
    /// the whole of what a new workspace gets to see.
    private var showsPlaceholder: Bool {
        transcript.isLoaded
            && !transcript.isRunning
            && !showsSetup
            // A workspace whose opening prompt is still queued, or whose first message is on its
            // way out, has nothing in its session and a bubble at the bottom of it. An empty state
            // centred over the pane would be drawn straight across the one thing on screen, which
            // is the same mistake `showsSetup` above is here to avoid.
            && transcript.hasNothingToShow
            // Last, and the position is the point rather than a tidying. `isStreaming` reads the
            // per-token buffers that `StreamingTailView` exists to keep out of this body: reading
            // one here subscribes the whole list to it, and every delta of every answer would run
            // a pass over every realised row. `&&` short-circuits, so a term that is only reached
            // when a session is loaded, idle, without a setup row and with nothing at all in it is
            // a term that is never reached while an answer is streaming. It used to sit second,
            // where the same short circuit saved it by accident.
            && !transcript.isStreaming
    }

    /// The rows this pass draws, which is every row of the session except on the frame that
    /// arrives at it.
    ///
    /// Opening a session on its live end resolves a position at the end of a `LazyVStack`, and
    /// that realises, measures and styles every row above it: 269ms of the main thread on a four
    /// thousand row session, which is the whole of the wait between clicking a workspace in the
    /// sidebar and seeing it, spent on rows thousands of points above the viewport. So the
    /// arrival draws `TranscriptTail`'s last eighty rows, and the history goes back behind them a
    /// frame later, where `defaultScrollAnchor(.bottom, for: .sizeChanges)` holds everything on
    /// screen exactly where it is while the content grows above it. Nothing moves; see `task`.
    ///
    /// This is the only thing in the app that ever sees part of a session. `transcript.rows` is
    /// the whole of it throughout, which is what the unread counts are computed over and what
    /// `TurnFooterView` hands to `TurnScan` to walk backwards through, and neither could be right
    /// over a slice that starts in the middle.
    private var visibleRows: ArraySlice<TranscriptRow> {
        let rows = transcript.rows
        guard drawnInFull != transcript.session.id else { return rows[...] }

        // Lazily, so the kinds are read through the rows rather than copied out of them. This is
        // asked on every pass, inside the arrival window the tail exists to protect, and the walk
        // reads at most twice the tail's length of them however long the session is.
        let start = TranscriptTail.start(in: rows.lazy.map(\.kind))
        guard start > 0 else { return rows[...] }
        // A session opens on the first thing the user has not read, and a scroll can only find a
        // row the list is drawing. Anything unread above the tail and there is no tail: opening in
        // the right place matters more than arriving quickly.
        if let unread = transcript.firstUnreadSeq, unread < rows[start].seq { return rows[...] }
        // Same rule for a search result, and it is the case that needs it most: the row somebody
        // searched for is nearly always old, and a scroll can only find a row the list is drawing.
        // Read rather than taken here, because a view body must not mutate; `position` takes it.
        if let target = app.pendingTranscriptTarget,
           target.workspaceID == transcript.workspace.id,
           target.seq < rows[start].seq {
            return rows[...]
        }
        return rows[start...]
    }

    /// What a link in any row of this transcript does. Its own property rather than an expression
    /// in the chain below, which is long enough that one more inline call tips the type checker
    /// off the `ForEach` two hundred lines above it.
    private var linkActions: TranscriptLinkActions {
        TranscriptLink.actions(for: app.existingModel(for: transcript.workspace.id))
    }

    /// Already rounded, by `TranscriptGeometry.cap`, and rounded before it reaches this view's
    /// state rather than after. A cap that changed on every pixel of a drag failed the row
    /// equality check on every realised row, once a frame.
    private var maxBubbleWidth: CGFloat { geometry.bubbleCap }

    var body: some View {
        // The first pass of this body after a tab switch, which is where the rebuilt list starts.
        // Stamped once per timeline, so the passes that follow it cost nothing to ignore.
        let _ = SwitchTrace.mark("transcript.body", workspace: transcript.workspace.id)
        let _ = SwitchTrace.markOnScreen("transcript.body", workspace: transcript.workspace.id)
        // Read once for the pass rather than once per footer: resolving it walks the row list,
        // and every realised footer would otherwise pay for its own walk. See `TranscriptModel`.
        let stoppedTurnSeq = transcript.stoppedTurnSeq
        // Only so the delete confirmation below has a binding to the model's own state. The
        // question cannot live in this view: see `TranscriptModel.discarding`.
        @Bindable var transcript = transcript

        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Before every row, because setting the workspace up is what happens before
                    // anything can be said in it. These are drawn from the workspace's own state
                    // rather than stored as rows, so a setup re-run replaces its line in place
                    // instead of leaving a second copy further down, and so none of it can ever
                    // reach the agent. See `WorkspaceEvent`.
                    WorkspaceEventsView(
                        workspaceID: transcript.workspace.id,
                        isRunning: isRunningSetup,
                        // Nothing said yet AND nothing waiting to be said. Once there is a bubble
                        // on screen, "You can ask for something now" is answered by the bubble,
                        // and answered better: it names the sentence that is waiting rather than
                        // describing the situation in the abstract.
                        isFirstThing: transcript.hasNothingToShow,
                        // The one row in this list sized as a share of the pane rather than of its
                        // own contents. Already rounded, by `TranscriptGeometry.height`, and
                        // rounded before it reaches this view's state for the reason the bubble cap
                        // is: see `maxBubbleWidth`.
                        paneHeight: geometry.paneHeight,
                        onVisibilityChange: { showsSetup = $0 },
                        onShowLogEnd: { wasAsked in
                            showSetupLogEnd(proxy, wasAsked: wasAsked)
                        }
                    )
                    // On the values, because the two closures above are rebuilt on every pass of
                    // this body and a struct holding a function can never compare equal to itself.
                    // Without this the feed re-ran its own body every time this list did, and that
                    // body rebuilds the setup timeline from a log that may be two hundred thousand
                    // characters long. See `WorkspaceEventsView.==`.
                    .equatable()

                    ForEach(visibleRows) { row in
                        if TranscriptNoise.isHidden(row) {
                            EmptyView()
                        } else if row.kind == .result {
                            // No top padding: the rule inside the footer carries its own air.
                            // The bottom is deliberately the wider of the two, so the footer
                            // reads as belonging to the turn above rather than to the one below.
                            // See `TranscriptLayout.turnGap`.
                            TurnFooterView(
                                rows: transcript.rows,
                                row: row,
                                worktree: transcript.workspace.path,
                                permissionMode: transcript.session.permissionMode,
                                // Only the turn the stop was about, which is at most one of them.
                                // See `TranscriptModel.stoppedTurnSeq`.
                                wasStopped: row.seq == stoppedTurnSeq,
                                // What is left of a wait this turn spent on somebody else's
                                // outage, or nothing, which is almost always.
                                recovered: transcript.recoveredRuns[row.seq]
                            )
                            .arrivingRow(isArriving(row))
                            .padding(.horizontal, TranscriptLayout.inset)
                            .padding(.bottom, TranscriptLayout.turnGap)
                            .id(row.seq)
                        } else {
                            TranscriptRowView(
                                row: row,
                                workspace: transcript.workspace,
                                isExpanded: expanded.contains(row.seq),
                                isNested: row.parentToolUseID != nil,
                                maxBubbleWidth: maxBubbleWidth,
                                projectName: transcript.projectName,
                                onToggle: { toggle(row.seq) },
                                onAnswer: { requestID, decision in
                                    Task { await transcript.answer(requestID: requestID, decision: decision) }
                                }
                            )
                            // Every pass over this list rebuilds every row the stack has already
                            // realised, and opening a long session realises all of them. Comparing
                            // the row's own values first is what keeps a second pass free.
                            .equatable()
                            // Innermost, on the drawing alone. What fades is what is inside the
                            // row: it is inserted at its full height exactly as it always was, so
                            // nothing moves, nothing reflows, and nothing below it shifts.
                            .arrivingRow(isArriving(row))
                            .padding(.horizontal, TranscriptLayout.inset)
                            .id(row.seq)
                        }
                    }

                    // Where the stored row for it will be, which is above the answer to it. The
                    // sentence is drawn here from the moment Return is pressed and is replaced by
                    // its `messages` row in the same place, at the same measure, in the same view:
                    // see `TranscriptModel.sending`, and `fades` below, which is what stops the
                    // stored row fading in over the top of a bubble already on screen.
                    if let sending = transcript.sending {
                        if let review = ReviewTurn.split(sending.body) {
                            UserTurnRowView(
                                text: review.message,
                                reviewChips: review.chips,
                                workspace: transcript.workspace,
                                maxWidth: maxBubbleWidth
                            )
                            // The owner's own bubble settles in like every other row that turns
                            // up. It is the one thing on this screen the reader made happen, and
                            // it was the only arrival with no settle at all: pressing Return put
                            // a bubble on screen in a single frame.
                            //
                            // Always true rather than asked of the tracker, because this view has
                            // no seq to ask about. It latches on its own `onAppear` and `sending`
                            // goes back to nil between turns, so the view is destroyed and rebuilt
                            // per message and each one settles exactly once.
                            .arrivingRow(true)
                            .padding(.horizontal, TranscriptLayout.inset)
                            .id(Self.sendingID)
                        } else {
                            let turn = AttachmentTrailer.split(sending.body)
                            UserTurnRowView(
                                text: turn.body,
                                attachments: turn.paths,
                                workspace: transcript.workspace,
                                maxWidth: maxBubbleWidth
                            )
                            .arrivingRow(true)
                            .padding(.horizontal, TranscriptLayout.inset)
                            .id(Self.sendingID)
                        }
                    }

                    StreamingTailView(transcript: transcript)
                        .padding(.horizontal, TranscriptLayout.inset)
                        .id(Self.streamingID)

                    // After everything that has been said, because that is where the next thing to
                    // be said belongs. Drawn from the workspace's queue rather than from a row, so
                    // none of it can reach the agent before it is actually sent: see
                    // `PendingTurnRowView` and `WorkspaceEvent`, which is the same rule.
                    ForEach(transcript.waitingDeliveries) { delivery in
                        PendingTurnRowView(
                            delivery: delivery,
                            // One sentence for the queue, at the foot of it. See the note on
                            // `PendingTurnRowView.caption`.
                            hold: delivery.id == transcript.waitingDeliveries.last?.id
                                ? transcript.deliveryHold
                                : nil,
                            maxWidth: maxBubbleWidth,
                            onDelete: { transcript.askToDiscard(delivery) }
                        )
                        .padding(.horizontal, TranscriptLayout.inset)
                        .id(Self.pendingID(delivery.id))
                    }
                }
                .padding(.vertical, TranscriptLayout.block)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Inside the content, so the scroll view behind the transcript can be found by
                // walking up from it. See `TranscriptScrollBridge`.
                .background(
                    TranscriptScrollBridge(scroller: scroller, follower: follower)
                        .frame(width: 0, height: 0)
                )
            }
            // A conversation shorter than the pane starts at the top of it, and only once there is
            // more of it than fits does the view sit at the live end.
            //
            // This anchor is ONLY about content that does not fill the pane, and it used to say
            // `.bottom`, on the argument that a conversation should hang just above the composer.
            // What that actually produced was a new workspace whose first line, "Session started",
            // was pinned to the bottom of a window with six hundred points of white above it: the
            // beginning of a conversation drawn at the end of the pane. A page of text starts at
            // the top of the page.
            //
            // Nothing about following a running turn changes. The stick-to-bottom behaviour is the
            // `.sizeChanges` anchor below, and opening a session on its live end is
            // `scrollPosition.scrollTo(edge: .bottom)` in `position`. Both are about content that
            // is longer than the pane, which is the case this one never sees.
            .defaultScrollAnchor(.top, for: .alignment)
            .scrollPosition($scrollPosition)
            // Held for the reader who has scrolled away, and not for the following.
            //
            // This was put here as what keeps the view at the live end while a turn runs, in place
            // of a `scrollTo` issued on every row that arrived: any scroll that names a position
            // inside a `LazyVStack` has to build and measure every row between the viewport and
            // that position, so following a turn re-rendered the entire transcript per row, and an
            // anchor asks for none of that. The argument holds. What does not is that the anchor
            // is what does the following. Measured on macOS 27.0 against a hosted `ScrollView` of
            // four thousand rows, with a `.scrollPosition` and without one, over a lazy stack and
            // an eager one, forced to `.bottom` and left to the flag below: appending a row moved
            // the content and never the offset, in any of the eight. What actually holds the view
            // at the end is the `ScrollPosition` above standing at `.bottom`, which does it in the
            // same layout pass that grows the content, and `TranscriptLiveEndFollower`, which
            // turns the last of that into something the eye can follow.
            //
            // It stays because it says the right thing and costs nothing: nil while the user has
            // scrolled away, which is the rule the per-row scroll used to enforce by hand. Yanking
            // someone back down as they read something further up is the single most irritating
            // thing a live log can do.
            // `isRevealingHistory` is the one pass that puts the history back under the reader,
            // where the content grows ABOVE the viewport rather than below it and the bottom edge
            // is what has to be held still. See the property for why it is a flag rather than a
            // second standing condition on the anchor.
            .defaultScrollAnchor(
                geometry.isNearBottom || isRevealingHistory ? .bottom : nil, for: .sizeChanges
            )
            .onScrollGeometryChange(for: TranscriptGeometry.self, of: Self.measure) { _, new in
                geometry = new
                // The state, every time, rather than only on a transition of it.
                //
                // This one fact had three copies: SwiftUI's own last projection, this view's
                // `geometry`, and the pane's flag that the pill is actually drawn from. Only the
                // first was ever authoritative, and the pane was told about CHANGES rather than
                // handed the answer, so any moment that moved one copy without moving the others
                // left the pill standing over a conversation the reader was already at the end of.
                // The session switch below is one such moment written into this file: it assigns
                // `geometry.isNearBottom` by hand and cannot reach SwiftUI's copy at all.
                //
                // It costs almost nothing to say it every time. This closure runs only when the
                // projected value changes, and both halves of that value are quantised: the cap
                // moves about once every eleven points of a drag, and the flag moves when the
                // reader arrives at or leaves the end. So the extra reports are a handful per
                // scroll, and each of them is a correction the transition form could not make.
                onScrolledUpChange?(!new.isNearBottom)
            }
            // A second subscription, on the raw offset, and deliberately not folded into the one
            // above. Everything in `TranscriptGeometry` is quantised precisely so that a drag
            // stops writing state; a raw offset in that value would undo the quantisation for all
            // of it. This one writes a box, which SwiftUI cannot see, so a scroll costs one
            // closure call per frame and no pass over this list. See `contentOffset`.
            .onScrollGeometryChange(for: Double.self) { $0.contentOffset.y } action: { _, new in
                contentOffset.value = new
                revealHistoryIfNeeded(approaching: new)
            }
            // Where the reader ends up, written down for the pane that is built next. On the end
            // of a gesture rather than during one: see `remember`.
            .onScrollPhaseChange { _, phase in
                if phase == .idle { remember() }
            }
            // And on the way out, which is the case the whole of `TranscriptResume` is about: a
            // tab switch destroys this view, and a reader who arrived, read what was on screen and
            // moved on has scrolled nothing for the closure above to fire on.
            .onDisappear { remember() }
            // `settlesArrivals`, like the two lists. It was dropped when the transcript moved to
            // `isNew`, which bounds itself; the transcript asks `arriving` again now, for the
            // reason written on `isArriving` below, so the window it opens has to be closed again.
            .settlesArrivals($arrival)
            .onChange(of: transcript.rows.count, initial: true) { _, _ in
                position(proxy)
                trackArrivals()
                // A row has landed, so the end of the content has moved. Between rows the tail
                // grows without any of this being told, which is what `isStreaming` below is for.
                follower.nudge()
            }
            // The three things that decide whether the follower may move anything, said out loud
            // rather than read from a body: it writes no state and reads none, so nothing else
            // would ever tell it. See `TranscriptLiveEndFollower`.
            .onChange(of: transcript.isStreaming, initial: true) { _, streaming in
                follower.isStreaming = streaming
            }
            .onChange(of: activeState, initial: true) { _, state in
                follower.isFrontmost = state != .inactive
            }
            .onChange(of: reduceMotion, initial: true) { _, reduced in
                follower.travels = TranscriptFollow.travels(reduceMotion: reduced)
            }
            // Asked for by the jump pill, and an edge rather than a row on purpose: the list is
            // drawing the end of the session and may not be holding the row a seq names yet.
            .onChange(of: transcript.liveEndRequests) { _, _ in
                goToLiveEnd()
            }
            .onChange(of: transcript.session.id) { _, _ in
                // Nothing is written down for the session being left here, and that is deliberate
                // rather than an omission. Everything `remember` reads describes the pane as it
                // was laid out a moment ago, and by the time this runs `transcript` is already the
                // NEW model: the row count would be the wrong session's. What the old session has
                // is whatever its last settled scroll wrote, which is a position in a document
                // that has only grown since, and that is exactly what `TranscriptResume` is built
                // to read back.
                //
                // Nothing owed to a conversation the pane has left.
                scroller.stop()
                follower.stop()
                catchUp?.cancel()
                didPosition = false
                opening = nil
                // The folds of the session being arrived at, which are its own and are usually
                // none. It used to be `removeAll`, which was the same claim for a session this
                // pane has never held and the wrong one for a session it is coming back to.
                let remembered = memory?.remembered(session: transcript.session.id)
                expanded = remembered?.expanded ?? []
                // A session opens at its live end whatever the one being left was scrolled to,
                // and the anchor is read before the new rows arrive.
                geometry.isNearBottom = true
                // And said out loud, because the report below is only made when the position
                // CHANGES, and a pane that arrives on the live end and stays there changes
                // nothing. Without this the composer keeps whatever the last session told it.
                onScrolledUpChange?(false)
                // Arriving somewhere means arriving on its tail, unless this pane has drawn the
                // session before, in which case there is nothing to arrive at: see
                // `TranscriptResume.drawsInFull`. Said here as well as in `task`, because leaving
                // a session before its history had landed and coming straight back would
                // otherwise find its own id still recorded and put four thousand rows on the
                // frame that is trying to arrive.
                drawnInFull = TranscriptResume.drawsInFull(remembered) ? transcript.session.id : nil
                // And what it still owes, for the same reason and at the same moment: a session
                // left before its history landed and come straight back to must not find the last
                // one's answer still standing. See `owesHistory`.
                owesHistory = TranscriptResume.opensOnTheTail(remembered)
                isRevealingHistory = false
                // And nothing in the session being arrived at counts as having arrived. Cleared
                // here as well as set in `task` for the same reason `drawnInFull` is: leaving a
                // session before it had settled and coming straight back must not find its own
                // id still recorded and fade its whole tail up.
                arrivalSession = nil
            }
            .task(id: transcript.session.id) {
                // Said before anything is awaited, because the first row can land inside the load
                // below. See `TranscriptLiveEndFollower.onRest`: the first frame the follower
                // steps takes SwiftUI's own hold on the live end down, and this is what gives it
                // back when the travel is over.
                //
                // The scroll position's own box rather than `settleAtLiveEnd`, which would be one
                // character shorter and would capture this view. The view holds the follower, the
                // follower would hold the closure, and a pane torn down mid turn would leave both
                // of them behind. A `State` box is not a view and closes no circle.
                follower.onRest = { [box = _scrollPosition] in box.wrappedValue.scrollTo(edge: .bottom) }
                // And the other half of that hand-off. A `ScrollPosition` standing at an edge is a
                // standing instruction SwiftUI reapplies on every layout pass that grows the
                // content, so the follower's take-back was being overwritten before it could be
                // drawn: the edge has to be let go of while the follower drives. Naming the
                // offset the view is already at moves nothing. See `onStart`.
                follower.onStart = { [box = _scrollPosition] y in box.wrappedValue.scrollTo(y: y) }
                await transcript.load()
                // Whatever the session arrived with, taken in without a fade. This runs whether
                // or not the row count changed, which matters: two sessions can hold the same
                // number of rows, and then nothing else would have told the tracker it is
                // looking at a different list.
                arrival.adopt(arrivalIDs)
                // And where the session opens, for the same reason: `position` is otherwise
                // driven by the row count's onChange, so a switch between two sessions holding
                // the same number of rows never positioned and never marked the session read,
                // and the unread badge stuck until the next row happened to land.
                position(proxy)

                // A pane coming back to the END of a session it has drawn before is holding a tail
                // and owes the history behind it, and owes it to a reader who scrolls towards it
                // rather than to a clock. Nothing above the viewport has to exist for the view to
                // be where it is, so putting it there now would be the whole of the arrival cost
                // paid for rows nobody has asked to see. See `revealHistoryIfNeeded`, which is
                // where it goes back, and `TranscriptResume.drawsInFull` for the measurement that
                // moved it.
                if owesHistory {
                    arrivalSession = transcript.session.id
                    SwitchTrace.mark("transcript.tail", workspace: transcript.workspace.id)
                    SwitchTrace.markOnScreen("transcript.tail", workspace: transcript.workspace.id)
                    return
                }

                // A pane coming back to a session it has drawn before has the whole of it on the
                // frame it arrived on and is already where the reader left it, so none of the
                // reveal below applies: there is no tail to grow into the history, nothing moves
                // under the viewport, and the two-call dance that exists because something does
                // has nothing to correct. Measured on a release build at 1440 by 900 against a
                // 3,848 row session: the reveal cost a 163ms to 169ms main thread block on every
                // return, on top of the 104ms to 125ms the tail before it cost, and this is the
                // whole of what removing it removes.
                //
                // It is skipped rather than deleted. On a FIRST open the sequence is still right
                // and `TranscriptTail` still carries the argument for it.
                guard drawnInFull != transcript.session.id else {
                    arrivalSession = transcript.session.id
                    // The same mark pair the deferred path carries below, so that a run of
                    // `TabProbe` before and after this change is comparing the same span: the
                    // moment the whole session is on the list, and the first frame that can show
                    // it. Here the first half is already true when this line is reached, which is
                    // the entire change.
                    SwitchTrace.mark("transcript.full", workspace: transcript.workspace.id)
                    SwitchTrace.markOnScreen("transcript.full", workspace: transcript.workspace.id)
                    return
                }

                // The rest of the session, once the frame carrying the tail has been drawn.
                //
                // A wait rather than a yield, because a yield is the same run loop pass and would
                // put the layout this exists to defer back on the frame it was taken off. Long
                // enough that the arrival is over and short enough to be finished before a hand
                // could reach the wheel, and it lands in the gap between the frame and the
                // answers the rest of the switch is still waiting on: the session query, `git
                // status`, and `gh`.
                //
                // Cancelled with the task when the session changes, so a switch that is left
                // before this lands never pays for the history of a workspace nobody is on.
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                drawnInFull = transcript.session.id
                // **The number the whole of this is about.** The work stamp is the instant the
                // history was asked for; the vsync stamp is the first frame that could show it,
                // and the display link cannot run while the main thread is laying rows out. The
                // gap between the two IS the layout `TranscriptTail` exists to keep off the
                // arrival frame, and on a return to a chat tab it is paid all over again.
                SwitchTrace.mark("transcript.full", workspace: transcript.workspace.id)
                SwitchTrace.markOnScreen("transcript.full", workspace: transcript.workspace.id)
                // Not an arrival. See `TranscriptLiveEndFollower.forget`.
                follower.forget()
                // And the live end again, in two calls, in two passes.
                //
                // **This is the "the chat text is gone" bug, and it is a fact about
                // `ScrollPosition` rather than about anchors.** Growing the content by four
                // thousand rows leaves the viewport where the tail's own end was, which is now a
                // couple of per cent down a document twenty-five times taller, over rows the lazy
                // stack has not realised: the transcript goes blank and stays blank. Filmed at the
                // time: rendered at 620ms, gone at 700ms, still gone three seconds later. The line
                // that was here to fix it, one `scrollTo(edge: .bottom)`, could not: a
                // `ScrollPosition` is a VALUE, and asking it for the edge it already names is not
                // a change, so SwiftUI has nothing to apply.
                //
                // Which is why it looked fixed. Arriving from another workspace, the position had
                // been moved off `.bottom` by the session being left, so the reassert was a real
                // change and landed. Coming back to a chat tab from an All changes tab, the pane
                // is built from nothing, the state starts at `ScrollPosition(edge: .bottom)` from
                // its own initialiser and is never moved off it, and the same line does nothing at
                // all. That is the "sometimes".
                //
                // Measured on a hosted `ScrollView` of four thousand rows, driven through exactly
                // this sequence: `scrollTo(edge: .bottom)` alone left the offset at the tail's
                // 4,100 of 239,300; a point named first and the edge named in the NEXT update
                // landed on 239,300 every time. Two updates, because both calls in one pass net
                // out to the same value and change nothing. The point itself moves nothing: it is
                // resolved against the content as it was before this pass, so it names where the
                // view already is, and it exists only to stop the edge being the value the state
                // already held.
                //
                // A row needs none of that, because `ScrollViewProxy.scrollTo` is a call rather
                // than a value and always acts, which is why the two openings are said through
                // one place that knows the difference. See `open`.
                if opening == .liveEnd {
                    scrollPosition.scrollTo(y: .greatestFiniteMagnitude)
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                }
                open(opening, with: proxy)
                // The session has finished arriving, so from here on a row that turns up is a row
                // the reader is watching turn up. The history that just landed is not one of them:
                // it was never absorbed, so every one of those rows latches at full opacity on the
                // frame it is built. See `ArrivingRow`.
                arrivalSession = transcript.session.id
                SwitchTrace.mark("transcript.history", workspace: transcript.workspace.id)
                SwitchTrace.markOnScreen("transcript.history", workspace: transcript.workspace.id)
            }
            // The anchor goes back to its standing value once the growth it was held for has been
            // laid out. A wait rather than a yield, for the reason the deferred reveal above gives:
            // a yield is the same run loop pass, and dropping the flag in the pass that asked for
            // the growth would drop it before the layout it exists for. Long enough to be sure of
            // that and short enough that a turn arriving cannot be dragged into view behind it,
            // which is the only thing a `.bottom` anchor left standing could do.
            .task(id: isRevealingHistory) {
                guard isRevealingHistory else { return }
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                isRevealingHistory = false
            }
            // Every chip in every row reports to this one object, which is why it is handed down
            // rather than passed as a closure through five layers of view. A closure would be a
            // new closure on every pass over the list and would invalidate every row that read it.
            .environment(\.transcriptHoverHost, hoverHost)
            // What a link in any row of this transcript does when it is pressed or chosen from a
            // menu. Said once for the whole list rather than per row, and comparable: this is a
            // computed property, so it really is a fresh struct on every pass, and until
            // `TranscriptLinkActions` was made `Equatable` on its identity SwiftUI counted the
            // environment attribute as changed every time and invalidated every reader. That went
            // straight through the `.equatable()` on the rows above.
            .markdownLinkActions(linkActions)
            .overlay {
                TranscriptHoverOverlay(host: hoverHost)
            }
            // A card that stayed up while the content moved under it would be pointing at a chip
            // that is no longer there. Phase changes rather than offsets: this fires when a scroll
            // begins and ends, not on every frame of one.
            .onScrollPhaseChange { _, phase in
                if phase != .idle { hoverHost.request = nil }
                // A hand on the wheel outranks anything this view asked for. `.animating` is our
                // own glide and is not a reason to drop it; the other two are the reader taking
                // hold, and a view that goes on dragging somebody somewhere after they have
                // grabbed it is the worst thing in this file.
                if phase == .tracking || phase == .interacting {
                    scroller.stop()
                    catchUp?.cancel()
                }
                // The follower is paused rather than stopped, and for deceleration too: a flick
                // that lands near the live end is still the reader's own movement, and something
                // pulling the last few points out from under the momentum is the same
                // interruption a drag would be. `.animating` is this app's own travel, which is
                // the one phase that is not somebody taking hold.
                follower.isPaused = phase != .idle && phase != .animating
            }
            .overlay {
                if showsPlaceholder {
                    TranscriptPlaceholderView(isRunningSetup: isRunningSetup)
                }
            }
            // Deleting a queued message asks first, in the app's own confirmation rather than a
            // shape of its own: `ConfirmationSheet` says why the app has one of these and not
            // two. On the list rather than on the row, so the question survives its row leaving,
            // which is exactly what happens when the queue moves while it is open.
            //
            // Not a toast with an undo, which is one gesture instead of two and was the tempting
            // alternative. What is being weighed here is minutes of somebody's thinking, the
            // window is the one place it exists, and an undo that is only offered for as long as
            // a banner is on screen protects it for eight seconds. The question is asked before
            // the loss, not after it.
            .confirmation($transcript.discarding) { delivery in
                let question = PendingMessageDiscard.question(
                    for: PendingMessageDiscard.recovery(
                        of: delivery, composerDraft: transcript.draft
                    )
                )
                return Confirmation(
                    title: question.title,
                    message: question.message,
                    confirmLabel: question.confirmLabel,
                    // Escape lands here. See `ConfirmationSheet` for why no confirmation in this
                    // app gives its cancel button `.keyboardShortcut(.defaultAction)`.
                    cancelLabel: question.cancelLabel
                )
            } onConfirm: { delivery in
                Task { await transcript.confirmDiscard(delivery) }
            }
        }
    }

    /// What the scroll view is telling us, projected down to the two things this view acts on.
    ///
    /// Whether the reader is at the end is `ScrollEnd`'s answer rather than a subtraction written
    /// here, and that is not tidiness. The two cases it adds are exactly the ones a subtraction
    /// gets wrong, and both of them float the jump pill over a conversation whose last line is
    /// already on screen: content that fits in the pane, and a pane with no height to fit it in.
    ///
    /// The bubble cap is worked out here, inside the projection, rather than in the body from a
    /// stored width. `onScrollGeometryChange` only calls its handler when the projected value
    /// changes, so rounding on this side of the line means a drag stops writing state, and stops
    /// re-running the list body, for the eleven points of travel between one cap and the next.
    private static func measure(_ scroll: ScrollGeometry) -> TranscriptGeometry {
        TranscriptGeometry(
            bubbleCap: TranscriptGeometry.cap(
                width: scroll.containerSize.width,
                share: bubbleShare,
                gutter: Metrics.gutter,
                floor: bubbleFloor
            ),
            paneHeight: TranscriptGeometry.height(scroll.containerSize.height),
            isNearBottom: ScrollEnd.isAtEnd(
                contentHeight: scroll.contentSize.height,
                viewportHeight: scroll.containerSize.height,
                offset: scroll.contentOffset.y
            ),
            reachToEnd: TranscriptGeometry.reach(
                contentHeight: scroll.contentSize.height,
                viewportHeight: scroll.containerSize.height,
                offset: scroll.contentOffset.y
            )
        )
    }

    // MARK: Scrolling

    /// Puts the newest line of the setup log on screen, and keeps it there while the script prints.
    ///
    /// **Unfolding a setup log grows this list rather than scrolling inside itself**, so this
    /// scroller is the only thing that can reach the end of one, and what that takes depends on
    /// what else is in the list.
    ///
    /// A setup script runs before the first turn, so the ordinary case is a session with no rows
    /// in it at all, and there the end of the log IS the live end of the transcript. Saying so
    /// through `scrollPosition` rather than by naming the row is the whole of why the view then
    /// keeps up: an edge is a standing instruction and a row is a place. Measured, on a script
    /// printing a line every 350ms into an unfolded row: naming the row landed on the newest line
    /// and then sat there while the content grew under it, eight points behind after one flush
    /// and a hundred and thirteen after eight, at which point the jump pill appeared over a log
    /// the reader had just asked to be shown the end of. Naming the edge holds it at nought.
    ///
    /// A session that already has rows is the re-run case, and there the live end is the last
    /// thing the agent said, which is not what a reader who pressed "Show more of the log" asked
    /// to see. So that one is taken to the row and left there.
    ///
    /// `wasAsked` separates the reader's own request from the log moving under them. The request
    /// is obeyed wherever they are. A flush is obeyed only while `isNearBottom` still says they
    /// are following along, which is the same test, at the same `ScrollEnd.threshold`, that decides
    /// whether a running turn is followed. There is one rule about dragging a reader in this
    /// window, and this is not a second one.
    private func showSetupLogEnd(_ proxy: ScrollViewProxy, wasAsked: Bool) {
        guard transcript.rows.isEmpty else {
            if wasAsked { proxy.scrollTo(WorkspaceEventRow.endID, anchor: .bottom) }
            return
        }
        guard wasAsked || geometry.isNearBottom else { return }
        scrollPosition.scrollTo(edge: .bottom)
    }

    /// Takes the reader back to the newest row, which is what the jump pill asks for.
    ///
    /// **A scroll rather than a jump, and the length of it is nearly the same however far it has
    /// to go.** See `TranscriptMotion.liveEndMove` for that argument; what belongs here is why it
    /// is safe. Every one of these names an EDGE, which resolves without the list having to build
    /// or measure a single row between here and there, and that is the difference between this and
    /// the per-row `scrollTo` that following a turn used to be. An animated scroll to a named row
    /// thousands of points down a `LazyVStack` would realise every row it passed, one per frame of
    /// the curve, which is the shape of the bug this file already carries two comments about.
    ///
    /// **The second scroll is for a turn that is still running.** The end of the content moves
    /// down while the glide is in the air, so it lands a little short, and short of the end is
    /// exactly the state in which `defaultScrollAnchor(for: .sizeChanges)` is dropped and the
    /// transcript stops following the tail. Saying the edge again on arrival closes the gap the
    /// glide could not see and re-attaches the follow in one move. Not animated: it is covering
    /// the two lines that arrived during the glide, not travelling anywhere.
    ///
    /// It is cancelled by a hand on the wheel, by leaving the session, and by a second press of
    /// the pill, which is the whole of what `catchUp` is for.
    private func goToLiveEnd() {
        catchUp?.cancel()

        let move = TranscriptMotion.liveEndMove(distance: geometry.reachToEnd, reduceMotion: reduceMotion)
        switch move {
        case .jump:
            scrollPosition.scrollTo(edge: .bottom)
        case .glide(let seconds):
            // AppKit rather than `withAnimation`, and `TranscriptLiveEndScroller` carries the
            // frame timings that settled that. A scroll view it cannot reach is not worth a
            // message: the press arrives instantly, which is what it did before any of this.
            guard scroller.glide(seconds: seconds, completion: settleAtLiveEnd) else {
                scrollPosition.scrollTo(edge: .bottom)
                return
            }
        }

        guard TranscriptMotion.reassertsLiveEnd(after: move, isStreaming: transcript.isStreaming),
              case .glide(let seconds) = move else { return }
        // Belt to the arrival handler's braces, and only a running turn is given one. The travel
        // ends by settling at the live end whatever happens; what a turn adds is that the end has
        // moved again since, so the same thing is worth saying once more a beat later.
        catchUp = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds + 0.05))
            guard !Task.isCancelled else { return }
            settleAtLiveEnd()
        }
    }

    /// Puts SwiftUI's own idea of where the list is back at the live end, without moving anything
    /// the reader can see.
    ///
    /// **Every completed travel owes this, because the travel happened underneath SwiftUI rather
    /// than through it.** `ScrollPosition` still believes the list is where the press started, and
    /// the next thing to read it would take the reader back there. Saying the edge unanimated
    /// costs one edge resolution, which realises nothing.
    ///
    /// It is also what the streaming case needed. The end of the content moves down while the
    /// travel is in the air, so the travel lands a little short of the end it was aimed at, and
    /// short of the end is exactly the state in which `defaultScrollAnchor(for: .sizeChanges)` is
    /// dropped and the transcript stops following the tail. This closes that gap and re-attaches
    /// the follow in one move. A travel that was stopped never reaches it, which is the point.
    private func settleAtLiveEnd() {
        scrollPosition.scrollTo(edge: .bottom)
    }

    /// Where a session opens: on the first thing the user has not read, which is the whole point
    /// of leaving a session and coming back to it, and otherwise on its live end.
    ///
    /// Both of these resolve a position inside a `LazyVStack`, which is the expensive kind of
    /// scroll: it realises every row it passes. So it happens once per session rather than once
    /// per row that arrives, and keeping up with a running turn is `TranscriptLiveEndFollower`'s
    /// job.
    /// Puts the history back behind a tail this pane opened on, once the reader scrolls near it.
    ///
    /// **A pane that comes back to the live end draws the tail and stops there.** Nothing above the
    /// viewport has to exist for the view to be where it is, so laying it out is work for rows
    /// thousands of points away that the reader has not asked to see, and on a return that is the
    /// whole of the wait: 114ms to 218ms on the owner's own session, measured with `--tab-probe`.
    /// This is what asking looks like.
    ///
    /// A pane's height ahead of the top, rather than at it. The growth is one main thread stop of
    /// the size the arrival used to be, and the point of doing it here is that the reader is still
    /// a screen away from the seam when it lands: they never see the rows arrive, they see a
    /// scroll that keeps going. Triggering at the top itself would put the stop exactly where the
    /// eye is.
    ///
    /// Once. `drawnInFull` is what the guard reads and what the reveal sets, so the growth cannot
    /// be asked for twice by the frames of one flick, and `owesHistory` is false for every pane
    /// that has nothing owed.
    private func revealHistoryIfNeeded(approaching offset: Double) {
        guard owesHistory, drawnInFull != transcript.session.id else { return }
        // **Not until the session has finished arriving, and this is not belt and braces.** A
        // scroll view reports its geometry from the moment it is laid out, which is several passes
        // before anything has put it on the live end, and its offset until then is nought. Without
        // this the reveal fired on the arrival frame every time, measured at 90ms to 109ms into a
        // return with `transcript.history.revealed` stamped right behind `transcript.tail`, which
        // is the whole of the saving handed straight back.
        guard arrivalSession == transcript.session.id else { return }
        // Nought until the pane has been measured, and a pane with no height cannot say what a
        // screen ahead of the top means. `TranscriptGeometry.height` reads nought the same way.
        guard geometry.paneHeight > 0, offset < geometry.paneHeight else { return }
        isRevealingHistory = true
        drawnInFull = transcript.session.id
        SwitchTrace.mark("transcript.history.revealed", workspace: transcript.workspace.id)
    }

    private func position(_ proxy: ScrollViewProxy) {
        guard !transcript.rows.isEmpty, !didPosition else { return }
        didPosition = true

        // A pane coming back to a session it has already drawn is put back where the reader left
        // it, and none of the three openings below applies: they are all answers to "where should
        // somebody arriving at this conversation start reading", and this reader is not arriving.
        // The rule, and what makes a written down position stale, is `TranscriptResume`'s.
        //
        // Still marked read at the foot of this function, because a turn can have run while the
        // pane was on another tab and those rows are rows the reader is now looking at.
        switch TranscriptResume.placement(
            for: memory?.remembered(session: transcript.session.id),
            rowCount: transcript.rows.count,
            measure: currentMeasure
        ) {
        case .liveEnd:
            opening = .liveEnd
        case .offset(let y):
            opening = .offset(y)
        case .first:
            // A search result outranks both of the others. Somebody who clicked a line of a
            // transcript in the search screen asked for that line, and taking them to their unread
            // mark or to the live end instead would be the app finding the answer and then hiding
            // it again. Centred rather than at the top, because the sentence usually needs the
            // turn around it to make sense.
            //
            // Which of the three it was is written down as it is chosen, because the history
            // landing behind this a moment later moves everything on screen and the view has to be
            // put back where it was put. See the reveal in `task`.
            if let target = app.takeTranscriptTarget(for: transcript.workspace.id) {
                opening = .row(target.seq, .center)
            } else if let unread = transcript.firstUnreadSeq, unread != transcript.rows.first?.seq {
                opening = .row(unread, .top)
            } else {
                opening = .liveEnd
            }
        }
        open(opening, with: proxy)
        Task { await transcript.markAllRead() }
    }

    // MARK: Remembering where the reader was

    /// What this pane is now, or nothing if it has not been laid out yet.
    ///
    /// `bubbleCap` rather than the container width, because that is the number this view actually
    /// holds and it is a step function of the width: see `TranscriptGeometry`, which explains why
    /// the raw width is deliberately not kept. `paneHeight` is nought until the first layout, and
    /// that is what tells an unmeasured pane apart from a narrow one.
    private var currentMeasure: TranscriptPaneState.Measure? {
        guard geometry.paneHeight > 0 else { return nil }
        return TranscriptPaneState.Measure(width: geometry.bubbleCap, fontScale: fontScale)
    }

    /// Writes down where the reader is, for the pane to find when it is built again.
    ///
    /// Called when a scroll settles, when a row is folded or unfolded, and when the pane goes
    /// away, rather than on every frame of a scroll. The last of those is the one that cannot be
    /// dropped: a reader who arrives, reads what is on screen and switches tab has scrolled
    /// nothing and folded nothing, and is exactly the case this whole file is about.
    private func remember() {
        guard let memory else { return }
        memory.remember(
            TranscriptPaneState(
                expanded: expanded,
                offset: contentOffset.value,
                isAtLiveEnd: geometry.isNearBottom,
                rowCount: transcript.rows.count,
                measure: currentMeasure
            ),
            session: transcript.session.id
        )
    }

    /// Puts the view where the session was opened.
    ///
    /// Said twice: once as the session arrives, and once more when its history has gone back in
    /// behind the tail, because that grows the content above the viewport and leaves it looking at
    /// something else entirely. See the reveal in `task` for why the live end takes two calls to
    /// say and a row takes one.
    private func open(_ opening: Opening?, with proxy: ScrollViewProxy) {
        switch opening {
        case .row(let seq, let anchor):
            proxy.scrollTo(seq, anchor: anchor)
        case .liveEnd:
            scrollPosition.scrollTo(edge: .bottom)
        case .offset(let y):
            // A point rather than an edge or a row, and it needs neither of the two dances above.
            // The content is already whole on the frame this runs on, so nothing grows underneath
            // it and there is nothing for the reveal to put back; and the value it is being moved
            // to is a value the state does not already hold, so one update is a change SwiftUI
            // applies. See the reveal in `task` for why the LIVE END takes two.
            scrollPosition.scrollTo(y: y)
        case nil:
            break
        }
    }

    // MARK: Arrivals

    /// The ids the tracker is shown: the live end of the session, and no more of it than that.
    ///
    /// Plain sequence numbers rather than anything session scoped, because `adopt` replaces the
    /// tracker's whole idea of the list every time a session loads. A seq that means one row in
    /// one session and a different row in the next can never be compared against the wrong one.
    private var arrivalIDs: [Int] {
        transcript.rows.suffix(Self.arrivalWindow).map(\.seq)
    }

    /// Takes the list in and works out what is new about it, unless the session is still arriving.
    private func trackArrivals() {
        guard arrivalSession == transcript.session.id else {
            arrival.adopt(arrivalIDs)
            return
        }
        arrival.absorb(arrivalIDs)
    }

    /// Whether this row should settle rather than appear.
    ///
    /// `isNew` rather than `isArriving`, and that is not a tidy-up. A row of this list is realised
    /// in the same pass that created it, and `trackArrivals` runs after that pass, so a row asking
    /// whether it had been announced as arriving was asking before anything could have announced
    /// it. Filmed against a real turn: twenty-three rows built, twenty-three of them told they
    /// were not arriving, and no row in the transcript had ever settled. `isNew` asks whether the
    /// tracker has yet to see this row, which is answerable on the frame the row is built.
    ///
    /// The kind is checked first, because it is free and it is no for the two kinds that make up
    /// most of a long session, and what follows it is a set lookup on an integer.
    private func isArriving(_ row: TranscriptRow) -> Bool {
        guard TranscriptMotion.fadesOnArrival(row.kind) else { return false }
        // **`arriving` and nothing else, because only a set difference can tell a new row from an
        // old one nobody has looked at yet.**
        //
        // `onChange(of: rows.count)` fires the moment the count moves, and a `LazyVStack` does not
        // build the new row until layout, which is after that. So by the time a row asks, `absorb`
        // has already taken the new list in and put the arrival in `arriving`: the answer is ready
        // exactly when it is wanted, and `settlesArrivals` closes the window a moment later.
        //
        // It was briefly `isNew(seq) || isArriving(seq)`, and the first half is what made rows
        // fade while the reader scrolled up through a long session. `known` only ever holds the
        // last `arrivalWindow` rows, so every row older than that is absent from it, and "absent"
        // is not "new": the row was realised for the first time because it came into view, not
        // because it had just landed. A set difference cannot make that mistake, which is what the
        // note on `arrivalWindow` says and what only `arriving` actually delivers.
        return arrival.isArriving(row.seq)
    }

    private func toggle(_ seq: Int) {
        // The unfold is animated from here rather than inside the row, because the height that
        // changes is the row's and the state that changes it is the list's: an `.animation` on the
        // row would be aimed at a value it does not own. `withAnimation` around the mutation is
        // what carries into the `if` inside `ToolRowView` and lets its transition play.
        let unfold = {
            if expanded.contains(seq) {
                expanded.remove(seq)
            } else {
                expanded.insert(seq)
            }
        }
        if let seconds = TranscriptMotion.disclosure(reduceMotion: reduceMotion) {
            withAnimation(.easeOut(duration: seconds), unfold)
        } else {
            unfold()
        }
        // Written down straight away rather than left to the next settled scroll, because
        // unfolding a tool result and switching tab to look at what it did is one gesture, and
        // re-folding it behind the reader's back was the bug. See `TranscriptResume`.
        remember()
    }
}
