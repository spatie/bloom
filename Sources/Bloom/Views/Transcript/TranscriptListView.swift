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
    let onScrolledUpChange: (@MainActor @Sendable (Bool) -> Void)?

    /// Expansion is a property of this view, not of the session. Reopening a workspace should not
    /// restore forty open tool results, and the model has no business knowing what is unfolded.
    @State private var expanded: Set<Int> = []
    @State private var geometry = TranscriptGeometry()
    @State private var didPosition = false

    /// The chip or the row the pointer is resting on, shared with every row in the list.
    ///
    /// Held here because the card has to be drawn here: a card next to a chip inside the lazy
    /// stack is clipped by the pane. Only `TranscriptHoverOverlay` reads it, so a hover never
    /// re-runs this body. See `TranscriptHoverHost`.
    @State private var hoverHost = TranscriptHoverHost()

    /// Only to reach the workspace's model, which is what a link opened in a browser tab needs.
    /// Nothing in `body` reads anything else off it.
    @Environment(AppModel.self) private var app

    /// Every programmatic move to the live end goes through this: opening a session on its end,
    /// the jump pill, history arriving, and the setup log's reveal. An edge needs no identity,
    /// so none of them needs the sentinel row the `ScrollViewReader` used to be pointed at.
    @State private var scrollPosition = ScrollPosition(edge: .bottom)

    /// Which rows have only just turned up, so they fade in rather than appear at full opacity in
    /// a single frame. The rules for what counts as "just turned up" are `RowArrival`'s, which is
    /// the same mechanism and the same 180ms the sidebar and Home settle their rows on.
    @State private var arrival = RowArrival<String>()

    /// The session the tracker above is following.
    ///
    /// Nothing fades until a session has finished arriving. Switching workspaces hands this list
    /// eighty rows in one frame and the rest of the history a beat later, and neither is work
    /// turning up in front of the reader: it is the pane being pointed somewhere else. See
    /// `trackArrivals` and the `task` below, which is where a session stops arriving.
    @State private var arrivalSession: SessionID?

    /// The session whose history has been put back, if any. See `visibleRows`.
    ///
    /// A session id rather than a flag, because this view is the same view in the same place for
    /// every workspace the window visits, and a flag left standing from the last one would draw
    /// the next one's whole history onto the frame that is trying to arrive.
    @State private var drawnInFull: SessionID?

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
            && !transcript.isStreaming
            && !showsSetup
            // A workspace whose opening prompt is still queued, or whose first message is on its
            // way out, has nothing in its session and a bubble at the bottom of it. An empty state
            // centred over the pane would be drawn straight across the one thing on screen, which
            // is the same mistake `showsSetup` above is here to avoid.
            && transcript.hasNothingToShow
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

        let start = TranscriptTail.start(in: rows.map(\.kind))
        guard start > 0 else { return rows[...] }
        // A session opens on the first thing the user has not read, and a scroll can only find a
        // row the list is drawing. Anything unread above the tail and there is no tail: opening in
        // the right place matters more than arriving quickly.
        if let unread = transcript.firstUnreadSeq, unread < rows[start].seq { return rows[...] }
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
        // Read once for the pass rather than once per footer: resolving it walks the row list,
        // and every realised footer would otherwise pay for its own walk. See `TranscriptModel`.
        let stoppedTurnSeq = transcript.stoppedTurnSeq

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
                                wasStopped: row.seq == stoppedTurnSeq
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
                            onCancel: { Task { await transcript.cancel(delivery) } }
                        )
                        .padding(.horizontal, TranscriptLayout.inset)
                        .id(Self.pendingID(delivery.id))
                    }
                }
                .padding(.vertical, TranscriptLayout.block)
                .frame(maxWidth: .infinity, alignment: .leading)
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
            // What keeps the view at the live end while a turn runs, and it replaces a `scrollTo`
            // that used to be issued on every row that arrived. Any scroll that names a position
            // inside a `LazyVStack` has to build and measure every row between the viewport and
            // that position, so following a turn re-rendered the entire transcript per row. An
            // anchor asks for none of that.
            //
            // Nil while the user has scrolled away, which is the whole of the rule that scroll
            // used to enforce by hand. Yanking someone back down as they read something further up
            // is the single most irritating thing a live log can do, and an absent anchor leaves
            // them exactly where they are.
            .defaultScrollAnchor(geometry.isNearBottom ? .bottom : nil, for: .sizeChanges)
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
            .settlesArrivals($arrival)
            .onChange(of: transcript.rows.count, initial: true) { _, _ in
                position(proxy)
                trackArrivals()
            }
            // Asked for by the jump pill, and an edge rather than a row on purpose: the list is
            // drawing the end of the session and may not be holding the row a seq names yet. Not
            // animated, because the distance being covered is usually thousands of points and a
            // fifth of a second of that is a blur rather than a sense of where you went.
            .onChange(of: transcript.liveEndRequests) { _, _ in
                scrollPosition.scrollTo(edge: .bottom)
            }
            .onChange(of: transcript.session.id) { _, _ in
                didPosition = false
                expanded.removeAll()
                // A session opens at its live end whatever the one being left was scrolled to,
                // and the anchor is read before the new rows arrive.
                geometry.isNearBottom = true
                // And said out loud, because the report below is only made when the position
                // CHANGES, and a pane that arrives on the live end and stays there changes
                // nothing. Without this the composer keeps whatever the last session told it.
                onScrolledUpChange?(false)
                // Arriving somewhere means arriving on its tail. Cleared here as well as set in
                // `task`, because leaving a session before its history had landed and coming
                // straight back would otherwise find its own id still recorded and put four
                // thousand rows on the frame that is trying to arrive.
                drawnInFull = nil
                // And nothing in the session being arrived at counts as having arrived. Cleared
                // here as well as set in `task` for the same reason `drawnInFull` is: leaving a
                // session before it had settled and coming straight back must not find its own
                // id still recorded and fade its whole tail up.
                arrivalSession = nil
            }
            .task(id: transcript.session.id) {
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
                // And the live end again, in the same breath.
                //
                // The size-change anchor is what holds the view still while the history lands,
                // and it is only in force while `isNearBottom` says the user is following along.
                // On the first visit of a launch that is not reliably true at this instant: the
                // rows arrive into a scroll view that is already on screen and already empty, so
                // there is a pass where the content is tall and the offset is still zero, the
                // measurement says the user is a long way from the end, and the anchor is dropped
                // for exactly as long as it takes the arrival to scroll itself down. Growing the
                // content by four thousand rows with no anchor moved the viewport into a part of
                // the stack that is not realised, and the transcript went blank and stayed blank.
                // Filmed: rendered at 620ms, gone at 700ms, still gone three seconds later.
                //
                // A session that has just been arrived at is at its live end by construction, so
                // saying so again costs nothing and cannot be wrong. It is not a second walk over
                // the rows either: the anchor has already moved the viewport, and this only names
                // the edge it is already on.
                scrollPosition.scrollTo(edge: .bottom)
                // The session has finished arriving, so from here on a row that turns up is a row
                // the reader is watching turn up. The history that just landed is not one of them:
                // it was never absorbed, so every one of those rows latches at full opacity on the
                // frame it is built. See `ArrivingRow`.
                arrivalSession = transcript.session.id
                SwitchTrace.mark("transcript.history", workspace: transcript.workspace.id)
                SwitchTrace.markOnScreen("transcript.history", workspace: transcript.workspace.id)
            }
            // Every chip in every row reports to this one object, which is why it is handed down
            // rather than passed as a closure through five layers of view. A closure would be a
            // new closure on every pass over the list and would invalidate every row that read it.
            .environment(\.transcriptHoverHost, hoverHost)
            // What a link in any row of this transcript does when it is pressed or chosen from a
            // menu. Said once for the whole list rather than per row, so it is one value the rows
            // can compare rather than a new closure on every pass.
            .markdownLinkActions(linkActions)
            .overlay {
                TranscriptHoverOverlay(host: hoverHost)
            }
            // A card that stayed up while the content moved under it would be pointing at a chip
            // that is no longer there. Phase changes rather than offsets: this fires when a scroll
            // begins and ends, not on every frame of one.
            .onScrollPhaseChange { _, phase in
                if phase != .idle { hoverHost.request = nil }
            }
            .overlay {
                if showsPlaceholder {
                    TranscriptPlaceholderView(isRunningSetup: isRunningSetup)
                }
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

    /// Where a session opens: on the first thing the user has not read, which is the whole point
    /// of leaving a session and coming back to it, and otherwise on its live end.
    ///
    /// Both of these resolve a position inside a `LazyVStack`, which is the expensive kind of
    /// scroll: it realises every row it passes. So it happens once per session rather than once
    /// per row that arrives, and keeping up with a running turn is the size-change anchor's job.
    private func position(_ proxy: ScrollViewProxy) {
        guard !transcript.rows.isEmpty, !didPosition else { return }
        didPosition = true

        if let unread = transcript.firstUnreadSeq, unread != transcript.rows.first?.seq {
            proxy.scrollTo(unread, anchor: .top)
        } else {
            scrollPosition.scrollTo(edge: .bottom)
        }
        Task { await transcript.markAllRead() }
    }

    // MARK: Arrivals

    /// The ids the tracker is shown: the live end of the session, and no more of it than that.
    ///
    /// Plain sequence numbers rather than anything session scoped, because `adopt` replaces the
    /// tracker's whole idea of the list every time a session loads. A seq that means one row in
    /// one session and a different row in the next can never be compared against the wrong one.
    private var arrivalIDs: [String] {
        transcript.rows.suffix(Self.arrivalWindow).map { String($0.seq) }
    }

    /// Takes the list in and works out what is new about it, unless the session is still arriving.
    private func trackArrivals() {
        guard arrivalSession == transcript.session.id else {
            arrival.adopt(arrivalIDs)
            return
        }
        arrival.absorb(arrivalIDs)
    }

    /// Whether this row should fade rather than appear.
    ///
    /// The set is almost always empty, and it is checked first so that a pass over a long session
    /// does not build a string per realised row to ask a question whose answer is already no.
    private func isArriving(_ row: TranscriptRow) -> Bool {
        guard !arrival.arriving.isEmpty, Self.fades(row.kind) else { return false }
        return arrival.isArriving(String(row.seq))
    }

    /// Whether a row of this kind is new on the frame it lands.
    ///
    /// Prose and thinking are not. Both are streamed live first and stored afterwards, and
    /// `StreamingRowView` is lined up column for column with their stored twins precisely so that
    /// nothing moves when one replaces the other. Fading the stored row in would undo exactly
    /// that: the answer the reader is halfway through would go out and come back over a fifth of
    /// a second, which is the jump those columns exist to avoid.
    ///
    /// Nor is a user turn, and that changed when the echo did. The sentence is drawn from the
    /// queue the instant Return is pressed and the stored row replaces it in the same place at the
    /// same measure, so fading it in would take the owner's own message away and bring it back
    /// over a fifth of a second, which is the flicker the echo exists to remove. See
    /// `TranscriptModel.sending`.
    ///
    /// Everything else genuinely arrives. A tool row lands where a "Running Bash" line was, and a
    /// turn footer lands where the status was.
    private static func fades(_ kind: MessageKind) -> Bool {
        switch kind {
        case .assistantText, .thinking, .user: false
        default: true
        }
    }

    private func toggle(_ seq: Int) {
        if expanded.contains(seq) {
            expanded.remove(seq)
        } else {
            expanded.insert(seq)
        }
    }
}
