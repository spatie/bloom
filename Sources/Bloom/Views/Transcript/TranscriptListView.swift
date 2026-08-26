import AppKit
import BloomCore
import SwiftUI

/// Every row of a session, and the rules for where the view sits among them.
///
/// It is an `NSTableView` rather than a `ScrollView` over a `LazyVStack`, and rather than a
/// `List`, and `TranscriptTable` carries the measurements that settled that. What belongs here is
/// what the change bought this file: a table can be told to put a reader back on the ROW they were
/// on rather than at the point they were at, and it knows every row's height, so almost every
/// piece of bookkeeping the lazy stack needed to keep somebody's place has gone with it.
///
/// **What went, and why it is not missed.** The `.equatable()` on each row, because a table
/// recycles on a content key and never rebuilds a cell whose key has not moved. The two-call dance
/// every scroll needed, because `ScrollPosition` was a value and naming the edge it already stood
/// at was not a change SwiftUI could apply, where a call on a table always acts. The bottom anchor
/// held over a growth, because rows going in above the reader move nothing when the reader's place
/// is a row. `TranscriptVisibleRows`, because the table can simply be asked which row is at the
/// top of the pane. And `TranscriptScrollBridge`, because the table owns its scroll view and says
/// which one it is instead of a planted view walking up from inside the content.
///
/// **What did not go, and is now said out loud.** A `ScrollPosition` standing at `.bottom` was a
/// standing instruction SwiftUI reapplied on every layout pass that grew the content, and that is
/// the whole of how the transcript used to stay with a running turn. AppKit has nothing of the
/// sort, so the instruction is explicit: `TranscriptTableController.goToEnd` holds it and the
/// coordinator re-asserts it. Every place this file used to say `scrollTo(edge: .bottom)` says
/// that instead.
struct TranscriptListView: View {
    let transcript: TranscriptModel
    /// Only to explain an empty transcript: a workspace whose setup script is still running has a
    /// session but cannot have said anything yet.
    var isRunningSetup: Bool = false
    /// The words this pane's empty state uses, when they are not the standard ones. See
    /// `TranscriptPlaceholderView.emptyState`.
    var emptyState: TranscriptEmptyState?
    /// Where this pane's place in this conversation is kept while the pane does not exist. Nil for
    /// a transcript nobody comes back to, which is the archive sheet's. See `TranscriptResume`.
    let memory: TranscriptPaneMemory?
    let onScrolledUpChange: (@MainActor @Sendable (Bool) -> Void)?

    init(
        transcript: TranscriptModel,
        isRunningSetup: Bool = false,
        emptyState: TranscriptEmptyState? = nil,
        memory: TranscriptPaneMemory? = nil,
        onScrolledUpChange: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        self.transcript = transcript
        self.isRunningSetup = isRunningSetup
        self.emptyState = emptyState
        self.memory = memory
        self.onScrolledUpChange = onScrolledUpChange
        // Seeded here rather than restored from a `task`, because both of these decide what the
        // FIRST pass of this body draws and a task runs after it. `remembered` reads a dictionary
        // that is `@ObservationIgnored`, so asking costs nothing and subscribes to nothing.
        let remembered = memory?.remembered(session: transcript.session.id)
        _expanded = State(initialValue: remembered?.expanded ?? [])
        let rows = transcript.rows
        _drawn = State(initialValue: Drawn(
            session: transcript.session.id,
            window: TranscriptResume.window(
                remembered,
                tailStart: TranscriptTail.start(in: rows.lazy.map(\.kind)),
                rowCount: rows.count
            )
        ))
        _resumed = State(
            initialValue: TranscriptResume.isResuming(remembered) ? transcript.session.id : nil
        )
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
    /// The width a bubble may fill, held as an object rather than in `geometry` so a pane changing
    /// width invalidates the handful of views that draw a bubble rather than this whole body. See
    /// `TranscriptBubbleWidth`, which carries the measurement that moved it.
    @State private var bubbleWidth = TranscriptBubbleWidth()
    /// The chip or the row the pointer is resting on, shared with every row in the list.
    ///
    /// Held here because the card has to be drawn here: a card next to a chip inside the table is
    /// clipped by the pane. Only `TranscriptHoverOverlay` reads it, so a hover never re-runs this
    /// body. See `TranscriptHoverHost`.
    @State private var hoverHost = TranscriptHoverHost()
    @State private var didPosition = false
    @State private var showsSetup = false
    /// Whether the window has grown in the last moment, which is the throttle on `growWindow`.
    ///
    /// **In a box, because nothing in the body reads it and as `@State` it cost a full pass to
    /// clear.** Growing the window writes `drawn`, which is a pass this list owes: four hundred
    /// rows really did arrive. Clearing this flag a fifth of a second later owed nothing at all,
    /// and it rebuilt every entry in the window to change a boolean no view draws from. On the
    /// owner's 2,981 row session an upward scroll grows about eight times, so that was eight
    /// rebuilds of up to 2,981 entries each, for nothing. See `GeometryBox`.
    @State private var isGrowing = GeometryBox(false)
    @State private var resumed: SessionID?
    @State private var opening: Opening?
    @State private var writingTo: WriteTarget?
    /// Where the scroll view is now, so that leaving the pane can write it down.
    ///
    /// In a box rather than in `@State` for the reason `GeometryBox` sets out: this is written on
    /// every frame of every scroll, and as `@State` every one of those frames would re-run this
    /// body, to store a number the body never reads.
    @State private var contentOffset = GeometryBox(0.0)
    /// How far below the viewport the end of the conversation is, read for one thing only: how
    /// long the jump pill's travel back to the live end should run for.
    @State private var reachToEnd = GeometryBox(0.0)
    /// The row at the top of the pane, in a box for the reason the two above are: it moves on
    /// every frame of a scroll and nothing draws from it. It replaces the set of visible row ids the
    /// lazy stack had to keep, because a table can simply be asked which row is at the top.
    @State private var topSeq = GeometryBox(0)

    /// Which rows have only just turned up, so they settle in rather than appear at full opacity
    /// in a single frame. An object rather than `@State` because a table's cells are built after
    /// this body has run: see `TranscriptArrivals`.
    @State private var arrivals = TranscriptArrivals()

    /// The session the tracker above is following.
    ///
    /// Nothing settles until a session has finished arriving. Switching workspaces hands this pane
    /// eighty rows in one frame and the rest of the history a beat later, and neither is work
    /// turning up in front of the reader: it is the pane being pointed somewhere else.
    @State private var arrivalSession: SessionID?

    @State private var controller = TranscriptTableController()
    /// The travel the jump pill makes. See `TranscriptLiveEndScroller`, which carries the frame
    /// timings that put an AppKit level scroll there in place of a `withAnimation`.
    @State private var scroller = TranscriptLiveEndScroller()
    /// What keeps the view with the newest row while a turn runs. See `TranscriptLiveEndFollower`.
    /// Nothing in this body reads it, on purpose: it writes no SwiftUI state, so following a turn
    /// costs no pass over this list.
    @State private var follower = TranscriptLiveEndFollower()

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Whether this window is the one in front, which is the whole of what the follower needs it
    /// for: a display link in a backgrounded app is a battery cost with nobody watching it.
    @Environment(\.controlActiveState) private var activeState
    /// The text scale the rows are drawn at, which is part of what the height cache is keyed on: a
    /// row at a different size is a different height, and an offset written down at one size is a
    /// point into a document laid out at another.
    @Environment(\.fontScale) private var fontScale
    @Environment(\.chatFont) private var chatFont

    /// How much of the session the table is being handed, and which session that is about.
    ///
    /// A session id rather than a bare index, because this view is the same view in the same place
    /// for every workspace the window visits, and a window left standing from the last one would
    /// name a row in a conversation nobody is looking at.
    private struct Drawn: Equatable {
        var session: SessionID
        var window: TranscriptWindow
    }

    @State private var drawn: Drawn

    /// Where `remember` writes, captured beside the state it is writing rather than read from the
    /// body when the write happens.
    ///
    /// **This view is not torn down when the reader changes workspace.** The centre column hands
    /// the same view a different model and a different session, so by the time anything notices
    /// the change, `memory` and `transcript` are already the conversation being ARRIVED at, while
    /// `drawn`, `contentOffset` and `geometry` still describe the one being left. `remember` read
    /// one half from each, so a scroll that settled in that window wrote the old conversation's
    /// place under the new conversation's key.
    private struct WriteTarget {
        var memory: TranscriptPaneMemory
        var session: SessionID
    }

    /// Where this session was opened, so the reveal can put it back there once the history has
    /// landed under it.
    ///
    /// Three openings and only one of them is the live end: a session opened on an unread mark or
    /// on a row somebody searched for was opened where the reader asked to be, and putting it back
    /// means putting it back THERE.
    private enum Opening: Equatable {
        case liveEnd
        case row(Int, UnitPoint)
        case offset(Double)
    }

    /// A user bubble takes this share of the pane, and never gets narrower than the floor, so a
    /// long prompt wraps sensibly and a short one still reads as one side of a conversation.
    private static let bubbleShare: CGFloat = 0.7
    private static let bubbleFloor: CGFloat = 240

    // MARK: - The rows

    /// The rows this pass draws, which is every row of the session except on the frame that
    /// arrives at it.
    ///
    /// Opening a session on its live end used to realise, measure and style every row above it:
    /// 269ms of the main thread on a four thousand row session. So the arrival draws
    /// `TranscriptTail`'s last eighty rows and the history goes in behind them a frame later.
    ///
    /// This is the only thing in the app that ever sees part of a session. `transcript.rows` is
    /// the whole of it throughout, which is what the unread counts are computed over and what
    /// `TurnFooterView` hands to `TurnScan` to walk backwards through, and neither could be right
    /// over a slice that starts in the middle.
    private var visibleRows: ArraySlice<TranscriptRow> {
        let window = drawnWindow
        return transcript.rows[window.start..<window.end]
    }

    /// The first row of the session this pass hands to the table.
    ///
    /// The window itself is state, because it only ever grows and a window recomputed from scratch
    /// on every pass would shrink back the moment the thing that widened it went away, taking the
    /// rows out from under the reader. What is computed here is the one thing that cannot be
    /// state: a row somebody has asked for by name has to be in the list on the very pass that
    /// asks for it, and `position` pins the answer the moment it has used it.
    private var drawnWindow: TranscriptWindow {
        let rows = transcript.rows
        guard drawn.session == transcript.session.id else {
            return TranscriptWindow.opening(
                rowCount: rows.count,
                tailStart: TranscriptTail.start(in: rows.lazy.map(\.kind)),
                mustReach: mustReachIndex
            )
        }
        let held = drawn.window.clamped(rowCount: rows.count)
        guard let mustReach = mustReachIndex, mustReach < held.start || mustReach >= held.end else {
            return held
        }
        return TranscriptWindow.opening(
            rowCount: rows.count, tailStart: held.start, mustReach: mustReach
        )
    }

    /// The row the reader has asked for by name, if there is one: a search result, or the unread
    /// mark a session opens on. A scroll can only find a row the table is drawing, so the window
    /// is opened wide enough to hold it whatever the tail said.
    private var mustReachIndex: Int? {
        let seqs = transcript.rows.lazy.map(\.seq)
        if let target = app.pendingTranscriptTarget,
           target.workspaceID == transcript.workspace?.id {
            return TranscriptWindow.index(ofSeqAtOrAfter: target.seq, in: seqs)
        }
        if let unread = transcript.firstUnreadSeq {
            return TranscriptWindow.index(ofSeqAtOrAfter: unread, in: seqs)
        }
        return nil
    }

    /// What a link in any row of this transcript does. Comparable, so that a fresh struct per pass
    /// is not a change: see `TranscriptRowEnvironment`, which is what carries it to the rows.
    private var linkActions: TranscriptLinkActions {
        TranscriptLink.actions(
            for: transcript.workspace.flatMap { app.existingModel(for: $0.id) }, pane: memory?.pane
        )
    }

    /// Only once the rows are known to be absent, so a session that is still loading does not flash
    /// an empty state on its way in, and not while setup is showing, which has something worth
    /// reading at the top of the pane.
    ///
    /// `isStreaming` is last, and the position is the point rather than a tidying: it reads the
    /// per-token buffers that `StreamingTailView` exists to keep out of this body, and `&&`
    /// short-circuits, so a term only reached when a session is loaded, idle, without a setup row
    /// and with nothing at all in it is a term never reached while an answer is streaming.
    private var showsPlaceholder: Bool {
        transcript.isLoaded
            && !transcript.isRunning
            && !showsSetup
            && transcript.hasNothingToShow
            && !transcript.isStreaming
    }

    /// Exactly what a hosted row needs, and nothing else. See `TranscriptRowEnvironment` for why
    /// this is a named list rather than `@Environment(\.self)`.
    private var rowEnvironment: TranscriptRowEnvironment {
        TranscriptRowEnvironment(
            app: app,
            hoverHost: hoverHost,
            bubbleWidth: bubbleWidth,
            linkActions: linkActions,
            fontScale: fontScale,
            chatFont: chatFont,
            reduceMotion: reduceMotion
        )
    }

    /// Everything the table draws, in order.
    ///
    /// Assembled on every pass over this body, which is what the lazy stack's `ForEach` was doing
    /// too. Nothing is BUILT here: each entry carries a closure the table calls when it measures or
    /// draws the row, so a session of four thousand rows costs four thousand closures rather than
    /// four thousand views.
    ///
    /// **The four entries that are not stored rows are always in the list, even when they draw
    /// nothing**, and that is not tidiness. The table compares this list against the last one to
    /// work out which rows arrived, and an entry appearing and disappearing in the middle of it is
    /// a shape it cannot express as a run: the bubble for a message on its way out used to come
    /// and go, so every message sent cost a full `reloadData()`, which throws away every cell and
    /// the reader's text selection with them. Present and empty, its content key moves and one row
    /// is rebuilt. A row that draws nothing takes no space: see `TranscriptRowHeights`.
    private var entries: [TranscriptTableEntry] {
        // Read once for the pass rather than once per row. Each is a property of an `@Observable`,
        // and observation is recorded where a property is READ: read inside a per-row closure,
        // every row registers its own edge on it. Measured on a release build resizing a window
        // over a 1,104 row conversation, six percent of the whole gesture was inside
        // `ObservationCenter.invalidate` doing exactly that. `projectName` is also worth a line of
        // its own: it reaches `AppModel.repo(for:)`, which is a linear scan.
        let home = transcript.home
        let projectName = transcript.projectName
        let rows = transcript.rows
        let permissionMode = transcript.session.permissionMode
        let recoveredRuns = transcript.recoveredRuns
        let stoppedTurnSeq = transcript.stoppedTurnSeq
        let paneHeight = geometry.paneHeight
        let arrivals = self.arrivals

        var out: [TranscriptTableEntry] = []
        // A workspace's setup script, its worktree events and its opening prompt. All three are
        // things a worktree has, so a conversation with none skips the entry rather than drawing
        // an empty one: see `TranscriptHome`.
        if let workspaceID = home.workspaceID {
            out.append(TranscriptTableEntry(
                id: .setup,
                contentKey: TranscriptContentKey {
                    $0.combine("setup")
                    $0.combine(workspaceID)
                    $0.combine(isRunningSetup)
                    $0.combine(transcript.hasNothingToShow)
                    $0.combine(Int(paneHeight))
                },
                content: {
                    AnyView(
                        WorkspaceEventsView(
                            workspaceID: workspaceID,
                            isRunning: isRunningSetup,
                            // Nothing said yet AND nothing waiting to be said. Once there is a bubble
                            // on screen, "You can ask for something now" is answered by the bubble.
                            isFirstThing: transcript.hasNothingToShow,
                            paneHeight: paneHeight,
                            onVisibilityChange: { showsSetup = $0 },
                            onShowLogEnd: { wasAsked in showSetupLogEnd(wasAsked: wasAsked) }
                        )
                        // The air the lazy stack got from `.padding(.vertical)` on its content. It
                        // cannot be a content inset here: see `TranscriptTable.makeNSView`.
                        .padding(.top, TranscriptLayout.block)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    )
                }
            ))
        }

        for row in visibleRows where !TranscriptNoise.isHidden(row) {
            let isExpanded = expanded.contains(row.seq)
            let wasStopped = row.seq == stoppedTurnSeq
            let recovered = recoveredRuns[row.seq]
            // The same fields `TranscriptRowView.==` compared, and for the same reason: the
            // payload is never read, because comparing it is 1.6MB of `Data` per pass.
            //
            // Whether the row is settling in is deliberately NOT here. It is asked when the cell
            // is built rather than baked in as this runs, and putting it in the key would rebuild
            // the cell again a fifth of a second later when the answer expired, throwing away the
            // settle it is meant to be showing. See `TranscriptArrivals`.
            let key = TranscriptContentKey {
                $0.combine(row.id)
                $0.combine(row.seq)
                $0.combine(row.kind)
                $0.combine(row.isError)
                $0.combine(row.durationMS)
                $0.combine(row.resultPayload?.count)
                $0.combine(row.permissionDecision)
                $0.combine(row.permissionNote)
                $0.combine(isExpanded)
                $0.combine(row.parentToolUseID)
                $0.combine(wasStopped)
                $0.combine(recovered != nil)
            }
            // Free, and no for the two kinds that make up most of a long session, so it is asked
            // here rather than inside the closure that runs per cell.
            let settles = TranscriptMotion.fadesOnArrival(row.kind)
            // What this row is worth before anybody draws it. Sixty per cent of a session draws
            // nothing, and the mean is a bad answer for every one of them: see `TranscriptRowInk`.
            let blank = TranscriptRowInk.drawsNothing(kind: row.kind, payload: row.payload)

            if row.kind == .result {
                out.append(TranscriptTableEntry(
                    id: .row(row.seq), contentKey: key, drawsNothing: blank,
                    content: {
                        AnyView(
                            // No top padding: the rule inside the footer carries its own air. The
                            // bottom is deliberately the wider of the two, so the footer reads as
                            // belonging to the turn above rather than to the one below.
                            TurnFooterView(
                                rows: rows,
                                row: row,
                                worktree: home.worktree,
                                permissionMode: permissionMode,
                                wasStopped: wasStopped,
                                recovered: recovered
                            )
                            .arrivingRow(settles && arrivals.isArriving(row.seq))
                            .padding(.horizontal, TranscriptLayout.inset)
                            .padding(.bottom, TranscriptLayout.turnGap)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        )
                    }
                ))
            } else {
                out.append(TranscriptTableEntry(
                    id: .row(row.seq), contentKey: key, drawsNothing: blank,
                    content: {
                        AnyView(
                            TranscriptRowView(
                                row: row,
                                home: home,
                                isExpanded: isExpanded,
                                isNested: row.parentToolUseID != nil,
                                projectName: projectName,
                                onToggle: { toggle(row.seq) },
                                onAnswer: { requestID, decision in
                                    Task { await transcript.answer(requestID: requestID, decision: decision) }
                                }
                            )
                            // Innermost, on the drawing alone. What settles is what is inside the
                            // row: the row is inserted at its full height exactly as it always
                            // was, so nothing moves, nothing reflows, and nothing below it shifts.
                            .arrivingRow(settles && arrivals.isArriving(row.seq))
                            .padding(.horizontal, TranscriptLayout.inset)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        )
                    }
                ))
            }
        }

        // Where the stored row for it will be, which is above the answer to it. The sentence is
        // drawn here from the moment Return is pressed and is replaced by its `messages` row in
        // the same place, at the same measure: see `TranscriptModel.sending`.
        let sending = transcript.sending
        out.append(TranscriptTableEntry(
            id: .sending,
            // The session is in the key for the reason `streaming` below carries: a pane visits
            // one conversation after another and the heights are remembered across the switch.
            contentKey: TranscriptContentKey {
                $0.combine("sending")
                $0.combine(transcript.session.id)
                $0.combine(sending?.id)
            },
            content: {
                guard let sending else { return AnyView(EmptyView()) }
                let review = ReviewTurn.split(sending.body)
                let turn = AttachmentTrailer.split(sending.body)
                return AnyView(
                    Group {
                        if let review {
                            UserTurnRowView(
                                text: review.message, reviewChips: review.chips, home: transcript.home
                            )
                        } else {
                            UserTurnRowView(
                                text: turn.body, attachments: turn.paths, home: transcript.home
                            )
                        }
                    }
                    // The owner's own bubble settles in like every other row that turns up. It is
                    // the one thing on this screen the reader made happen, and it was the only
                    // arrival with no settle at all: pressing Return put a bubble on screen in a
                    // single frame. Always true rather than asked of the tracker, because this
                    // view has no seq to ask about.
                    .arrivingRow(true)
                    .padding(.horizontal, TranscriptLayout.inset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                )
            }
        ))

        // The one entry that changes height without anything telling this view so, which is why
        // `TranscriptRowHeights` takes a correction from a drawn row as authoritative.
        out.append(TranscriptTableEntry(
            // **The session is part of the key, and it is load bearing.** The height cache
            // survives a workspace switch, and a bare "streaming" would hand the next
            // conversation the last one's tail height: a pane opening on its live end with
            // several hundred points of blank under the newest row, closing again the moment the
            // cell is drawn. Every stored row is keyed by a row id, which is unique across
            // sessions; these two are the only entries that are not.
            id: .streaming,
            contentKey: TranscriptContentKey {
                $0.combine("streaming")
                $0.combine(transcript.session.id)
            },
            content: {
                AnyView(
                    StreamingTailView(transcript: transcript)
                        .padding(.horizontal, TranscriptLayout.inset)
                        // The other half of the air. This entry is always in the list, and is
                        // nothing at all between turns, so it is also what stops the last row of a
                        // quiet conversation sitting against the bottom edge.
                        .padding(.bottom, TranscriptLayout.block)
                        .frame(maxWidth: .infinity, alignment: .leading)
                )
            }
        ))

        // After everything that has been said, because that is where the next thing to be said
        // belongs. Drawn from the workspace's queue rather than from a row, so none of it can
        // reach the agent before it is actually sent.
        for delivery in transcript.waitingDeliveries {
            let isLast = delivery.id == transcript.waitingDeliveries.last?.id
            // One sentence for the queue, at the foot of it. See `PendingTurnRowView.caption`.
            let hold = isLast ? transcript.deliveryHold : nil
            out.append(TranscriptTableEntry(
                id: .pending(delivery.id),
                contentKey: TranscriptContentKey {
                    $0.combine("pending")
                    $0.combine(delivery.id)
                    $0.combine(isLast)
                },
                content: {
                    AnyView(
                        PendingTurnRowView(
                            delivery: delivery,
                            hold: hold,
                            onEdit: { Task { await transcript.editPending(delivery) } },
                            onDelete: { transcript.askToDiscard(delivery) }
                        )
                        .padding(.horizontal, TranscriptLayout.inset)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    )
                }
            ))
        }
        // One increment and one add for the whole pass. See `TranscriptHoldCensus.entryPasses`:
        // this is the count that says whether a scroll is paying for the window rather than for
        // the screen.
        TranscriptHoldCensus.builtEntries(out.count)
        return out
    }

    // MARK: - Body

    var body: some View {
        // The first pass of this body after a tab switch, which is where the rebuilt list starts.
        // Stamped once per timeline, so the passes that follow it cost nothing to ignore.
        let _ = SwitchTrace.mark("transcript.body", workspace: transcript.workspace?.id)
        let _ = SwitchTrace.markOnScreen("transcript.body", workspace: transcript.workspace?.id)
        // Only so the delete confirmation below has a binding to the model's own state. The
        // question cannot live in this view: see `TranscriptModel.discarding`.
        @Bindable var transcript = transcript

        TranscriptTable(
            entries: entries,
            session: transcript.session.id,
            controller: controller,
            scale: fontScale,
            rowEnvironment: rowEnvironment,
            onGeometryChange: { measured($0) },
            onSettled: { remember() },
            onLiveScrollChange: { hasHold in
                // **A hand on the wheel outranks anything this view asked for.** The follower is
                // paused rather than stopped, and for the momentum too: a flick that lands near
                // the live end is still the reader's own movement, and something pulling the last
                // few points out from under it is the same interruption a drag would be.
                follower.isPaused = hasHold
                guard hasHold else { return }
                // A card that stayed up while the content moved under it would be pointing at a
                // chip that is no longer there.
                hoverHost.request = nil
                // And a view that goes on dragging somebody somewhere after they have grabbed it
                // is the worst thing in this file.
                scroller.stop()
            }
        )
        .overlay { TranscriptHoverOverlay(host: hoverHost) }
        .overlay {
            if showsPlaceholder {
                TranscriptPlaceholderView(isRunningSetup: isRunningSetup, emptyState: emptyState)
            }
        }
        // The case the whole of `TranscriptResume` is about: a tab switch destroys this view, and
        // a reader who arrived, read what was on screen and moved on has scrolled nothing for the
        // settle to fire on.
        .onDisappear { remember() }
        .onChange(of: transcript.rows.count, initial: true) { _, _ in
            position()
            // A row arriving is another chance to notice that the window stops short of it.
            growWindowDown()
            trackArrivals()
            // A row has landed, so the end of the content has moved. Between rows the tail grows
            // without any of this being told, which is what `isStreaming` below is for.
            follower.nudge()
        }
        // The things that decide whether the follower may move anything, said out loud rather than
        // read from a body: it writes no state and reads none, so nothing else would tell it.
        .onChange(of: transcript.isStreaming, initial: true) { _, streaming in
            follower.isStreaming = streaming
        }
        .onChange(of: activeState, initial: true) { _, state in
            follower.isFrontmost = state != .inactive
        }
        .onChange(of: reduceMotion, initial: true) { _, reduced in
            follower.travels = TranscriptFollow.travels(reduceMotion: reduced)
        }
        // Asked for by the jump pill, and by every button that composes a turn: see
        // `TranscriptModel.submit`, which bumps this so that what somebody just asked for is the
        // thing they are looking at.
        .onChange(of: transcript.liveEndRequests) { _, _ in
            goToLiveEnd()
        }
        .onChange(of: transcript.session.id) { _, _ in
            // The session being left is written down here, from its own measurements: `writingTo`
            // carries the pane and the session the drawn state belongs to, so this records the
            // conversation being left rather than the one being arrived at.
            remember()
            // Nothing owed to a conversation the pane has left.
            scroller.stop()
            follower.stop()
            controller.releaseEnd()
            didPosition = false
            opening = nil
            // The folds of the session being arrived at, which are its own and are usually none.
            let remembered = memory?.remembered(session: transcript.session.id)
            expanded = remembered?.expanded ?? []
            // A session opens at its live end whatever the one being left was scrolled to, and the
            // anchor is read before the new rows arrive.
            geometry.isNearBottom = true
            geometry.isFarFromEnd = false
            // And said out loud, because the report below is only made when the position CHANGES,
            // and a pane that arrives on the live end and stays there changes nothing.
            onScrolledUpChange?(false)
            drawn = Drawn(
                session: transcript.session.id,
                window: TranscriptResume.window(
                    remembered,
                    tailStart: TranscriptTail.start(in: transcript.rows.lazy.map(\.kind)),
                    rowCount: transcript.rows.count
                )
            )
            writingTo = memory.map { WriteTarget(memory: $0, session: transcript.session.id) }
            resumed = TranscriptResume.isResuming(remembered) ? transcript.session.id : nil
            isGrowing.value = false
            topSeq.value = 0
            // Nothing in the session being arrived at counts as having arrived. Cleared here as
            // well as set in `task`, because leaving a session before it had settled and coming
            // straight back must not find its own id still recorded and settle its whole tail.
            arrivalSession = nil
        }
        .task(id: transcript.session.id) {
            // **The table's half of the hand-off with the follower, and it is the argument the
            // lazy stack made about `ScrollPosition` arriving in AppKit.**
            //
            // There, a position standing at `.bottom` was reapplied by SwiftUI on every layout
            // pass that grew the content, so the follower's take-back was overwritten before it
            // could be drawn and the edge had to be let go of while it drove. Here the standing
            // instruction is this file's own, and the same two hand-offs settle the same fight:
            // the follower says when it takes the view, and says when it has put it down.
            // The controller rather than this view, for the reason the lazy stack captured a
            // `State` box rather than `self`: the view holds the follower, the follower would hold
            // the closure, and a pane torn down mid turn would leave both of them behind.
            follower.onStart = { [controller] _ in controller.followerTookOver() }
            follower.onStop = { [controller] in controller.followerHandedBack() }
            follower.onRest = { [controller] in controller.goToEnd() }
            await transcript.load()
            // The window, now that there are rows to work it out from. The initialiser and the
            // session's `onChange` both ran before this, and neither could name a tail.
            drawn = Drawn(
                session: transcript.session.id,
                window: TranscriptResume.window(
                    memory?.remembered(session: transcript.session.id),
                    tailStart: TranscriptTail.start(in: transcript.rows.lazy.map(\.kind)),
                    rowCount: transcript.rows.count
                )
            )
            TranscriptDrawn.note(drawn.window.count)
            writingTo = memory.map { WriteTarget(memory: $0, session: transcript.session.id) }
            // **And the positioning is owed again, because the one that has already run was run
            // too early to mean anything.** `position` latches on `didPosition`, and the row
            // count's `onChange` fires with `initial: true` before the load above has finished.
            didPosition = false
            // Whatever the session arrived with, taken in without a settle. This runs whether or
            // not the row count changed, which matters: two sessions can hold the same number of
            // rows, and then nothing else would have told the tracker it is looking at a
            // different list.
            arrivals.adopt(transcript.rows.suffix(TranscriptArrivals.window).map(\.seq))
            // A turn for the body to run with the window set above, so that the table holds the
            // rows the positioning is about to name.
            await Task.yield()
            guard !Task.isCancelled else { return }
            adoptScrollView()
            position()
            // **The pane may be drawn again now.** It has been blank since the session changed:
            // its rows are in, its window is chosen and `position` has applied the placement, so
            // what fades in is already where the reader left it rather than at the top on its way
            // there. Before the return below, because a pane coming back to a session it has
            // drawn before is exactly the switch that has to feel instant.
            //
            // One turn later than the positioning, and that is the point: every scroll in
            // `TranscriptTable` says itself twice, because the first is resolved against heights
            // the table has not corrected yet. The second lands on this turn, so what is revealed
            // is the corrected place rather than the place that is about to move.
            await Task.yield()
            guard !Task.isCancelled else { return }
            controller.arrived()

            // A pane coming back to a session it has drawn before is already in the window the
            // reader was reading in and already where they left off, so none of the reveal below
            // applies. Measured on a release build against a 3,848 row session: the reveal cost a
            // 163ms to 169ms main thread block on every return.
            guard resumed != transcript.session.id else {
                arrivalSession = transcript.session.id
                SwitchTrace.mark("transcript.window", workspace: transcript.workspace?.id)
                SwitchTrace.markOnScreen("transcript.window", workspace: transcript.workspace?.id)
                return
            }

            // A few hundred rows of history behind the tail, once the frame carrying the tail has
            // been drawn. A wait rather than a yield, because a yield is the same run loop pass
            // and would put the layout this exists to defer back on the frame it was taken off.
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            let settled = TranscriptWindow.settling(
                from: drawn.window, rowCount: transcript.rows.count
            )
            drawn = Drawn(session: transcript.session.id, window: settled)
            TranscriptDrawn.note(settled.count)
            SwitchTrace.mark("transcript.window", workspace: transcript.workspace?.id)
            SwitchTrace.markOnScreen("transcript.window", workspace: transcript.workspace?.id)
            // Not an arrival. See `TranscriptLiveEndFollower.forget`.
            follower.forget()
            // **And the opening again, in one call rather than the stack's two.**
            //
            // The stack needed two because a `ScrollPosition` standing at `.bottom` could not be
            // told `.bottom` again: the value had not changed, so SwiftUI had nothing to apply,
            // and the transcript went blank behind four thousand rows of history it had just been
            // handed. That argument is obsolete here, because a call on a table always acts and
            // because the history goes in ABOVE the viewport and the table puts the reader back on
            // the row they were on rather than at the point they were at. What is not obsolete is
            // that the content it lands on has only just been handed over, and `open` says each
            // destination twice on its own account for exactly that.
            await Task.yield()
            guard !Task.isCancelled else { return }
            open(opening)
            // The session has finished arriving, so from here on a row that turns up is a row the
            // reader is watching turn up. The history that just landed is not one of them.
            arrivalSession = transcript.session.id
            SwitchTrace.mark("transcript.history", workspace: transcript.workspace?.id)
            SwitchTrace.markOnScreen("transcript.history", workspace: transcript.workspace?.id)
        }
        // Deleting a queued message asks first, in the app's own confirmation. On the list rather
        // than on the row, so the question survives its row leaving, which is exactly what happens
        // when the queue moves while it is open.
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
                cancelLabel: question.cancelLabel
            )
        } onConfirm: { delivery in
            Task { await transcript.confirmDiscard(delivery) }
        }
    }

    // MARK: - Geometry

    /// The scroll view has moved or changed size. Everything the six `onScrollGeometryChange`
    /// subscriptions on the lazy stack did, in one callback, because there is only one place the
    /// numbers can come from now.
    private func measured(_ table: TranscriptTableGeometry) {
        adoptScrollView()

        // **On a change and never otherwise, and this one is not a saving, it is a bug.**
        //
        // `TranscriptBubbleWidth` is `@Observable`, and the setter a macro writes notifies on every
        // assignment rather than on every change: handing it the number it already holds
        // invalidates every view that reads it just the same. Written from here it was assigned on
        // every frame of every scroll, so every user bubble on screen was re-rendered and re-laid
        // out sixty times a second, for a cap that had not moved since the pane was last resized.
        // The lazy stack never had this, because `onScrollGeometryChange` only calls its handler
        // when the projected value changes, and this callback has no such filter in front of it.
        let cap = TranscriptGeometry.cap(
            width: table.viewportWidth,
            share: Self.bubbleShare,
            gutter: Metrics.gutter,
            floor: Self.bubbleFloor
        )
        if bubbleWidth.cap != cap { bubbleWidth.cap = cap }
        reachToEnd.value = TranscriptGeometry.reach(
            contentHeight: table.contentHeight,
            viewportHeight: table.viewportHeight,
            offset: table.offset
        )
        contentOffset.value = table.offset
        if let seq = controller.topmostEntry?.seq { topSeq.value = seq }

        var measured = TranscriptGeometry(
            paneHeight: TranscriptGeometry.height(table.viewportHeight),
            isNearBottom: ScrollEnd.isAtEnd(
                contentHeight: table.contentHeight,
                viewportHeight: table.viewportHeight,
                offset: table.offset
            ),
            isFarFromEnd: ScrollEnd.isWorthOffering(
                contentHeight: table.contentHeight,
                viewportHeight: table.viewportHeight,
                offset: table.offset
            )
        )
        // **The end of what is drawn is not the end of the conversation.**
        //
        // A window that stops short of the live end is a scroll view whose content ends where the
        // window does, and every measurement taken from that geometry says the reader has arrived
        // at the end: the pill that offers to take them to the newest row is not drawn, the pane
        // is written down as having been left at the live end, and the rows below are unreachable
        // because the only thing that grows the window downwards is noticing that the reader wants
        // them. Reported as "sometimes I cannot scroll to the end any more". So the geometry is
        // corrected before anything reads it, and the correction is the truth: there is more below.
        if drawn.session == transcript.session.id,
           drawn.window.canGrowDown(rowCount: transcript.rows.count) {
            measured.isNearBottom = false
            measured.isFarFromEnd = true
        }
        // Written only on a change, because this runs on every frame of every scroll and each
        // write is a pass over this body. The report to the composer goes with it: one per frame
        // would put the jump pill's own state write on the scroll path.
        if measured != geometry {
            geometry = measured
            onScrolledUpChange?(measured.isFarFromEnd)
        }

        if table.offset < table.viewportHeight { growWindow() }
        // A scroll that ended against the bottom of a short window is a reader asking for what is
        // under it, and the geometry may not have CHANGED while they tried.
        if measured.isNearBottom || table.contentHeight - table.viewportHeight - table.offset < 1 {
            growWindowDown()
        }
    }

    /// Hands the glide and the follower the scroll view the table is in.
    ///
    /// This replaces the zero sized view the lazy stack had to plant inside its scroll content so
    /// that `enclosingScrollView` had something to walk up from. There is no walking up any more:
    /// the table owns its `NSScrollView` and simply says which one it is.
    private func adoptScrollView() {
        let found = controller.scrollView
        if scroller.scrollView !== found { scroller.scrollView = found }
        if follower.scrollView !== found { follower.scrollView = found }
    }

    // MARK: - Scrolling

    /// Puts the newest line of the setup log on screen, and keeps it there while the script prints.
    ///
    /// **Unfolding a setup log grows this list rather than scrolling inside itself**, so this is
    /// the only thing that can reach the end of one, and what that takes depends on what else is
    /// in the list.
    ///
    /// A setup script runs before the first turn, so the ordinary case is a session with no rows
    /// in it at all, and there the end of the log IS the live end of the transcript. Saying so by
    /// asking to be AT the end rather than by naming the row is the whole of why the view then
    /// keeps up: measured, on a script printing a line every 350ms into an unfolded row, naming
    /// the row landed on the newest line and then sat there while the content grew under it, a
    /// hundred and thirteen points behind after eight flushes. The standing instruction holds it
    /// at nought.
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
    private func showSetupLogEnd(wasAsked: Bool) {
        guard transcript.rows.isEmpty else {
            // The height of a row that has just unfolded 1,381 lines of log is not known until it
            // has been drawn, so this lands short and is said again a turn later. That second call
            // is `TranscriptTable.Coordinator.scroll(to:anchor:)`'s own, rather than something
            // every caller has to remember.
            //
            // The whole feed is one row of the table, so this asks for the bottom of the feed
            // rather than for the end of the setup event inside it. The two are the same place
            // whenever setup is the last thing Bloom did to this workspace, which is the case a
            // reader unfolds a log in; a workspace with a later event in its feed would be taken
            // past the end of the log to the bottom of that. See `WorkspaceEventRow.endID`, which
            // is the sentinel that used to answer this exactly and what it would take to use it.
            if wasAsked { controller.scroll(to: .setup, anchor: .bottom) }
            return
        }
        guard wasAsked || geometry.isNearBottom else { return }
        controller.goToEnd()
    }

    /// Takes the reader back to the newest row, which is what the jump pill asks for, and what
    /// every button that composes a turn asks for through `TranscriptModel.submit`.
    ///
    /// **The travel is a scroll rather than a jump, and the length of it is nearly the same however
    /// far it has to go.** See `TranscriptMotion.liveEndMove` for that argument. What belongs here
    /// is why it is safe: the table knows where every row is, so a travel to the end costs one
    /// arithmetic rather than realising every row between here and there, which is what made the
    /// same movement over a `LazyVStack` a thing to be careful with.
    ///
    /// **And it ends by asking to BE at the end rather than by arriving there**, which is the
    /// whole of what was wrong with the first version. The end moves while the travel is in the
    /// air: a running turn grows the tail, the rows the travel lands among are drawn and turn out
    /// to be taller than they were measured at, and a window that has just been moved to the tail
    /// has not been laid out at all. Each of those leaves a scroll that was correct when it was
    /// issued a few hundred points short, and short of the end is exactly the state the reader
    /// pressed the pill to get out of. `goToEnd` is a standing instruction rather than a movement.
    private func goToLiveEnd() {
        // The live end has to be IN the window before anything can travel to it, and a reader far
        // enough from the end to press this is often reading a window that does not hold it.
        if drawn.session == transcript.session.id,
           drawn.window.canGrowDown(rowCount: transcript.rows.count) {
            drawn.window = TranscriptWindow.liveEnd(rowCount: transcript.rows.count)
            TranscriptDrawn.note(drawn.window.count)
            // **No travel when the window moved.** The rows a glide would pass through are not in
            // the table yet: they go in on the next pass over this body, and a travel aimed at the
            // end of the content as it stands now is aimed at a row that is about to be somewhere
            // else entirely. The standing instruction is what makes the arrival stick once they
            // have landed.
            scroller.stop()
            controller.goToEnd()
            return
        }

        switch TranscriptMotion.liveEndMove(
            distance: reachToEnd.value, reduceMotion: reduceMotion
        ) {
        case .jump:
            controller.goToEnd()
        case .glide(let seconds):
            // Let go of the end first, or the instruction and the travel are two things moving the
            // same clip view. AppKit rather than `withAnimation`: `TranscriptLiveEndScroller`
            // carries the frame timings that settled that.
            controller.releaseEnd()
            guard scroller.glide(
                seconds: seconds, completion: { [controller] in controller.goToEnd() }
            ) else {
                controller.goToEnd()
                return
            }
        }
    }

    /// Where a session opens: on the first thing the reader has not read, which is the whole point
    /// of leaving a session and coming back to it, and otherwise on its live end.
    private func position() {
        guard !transcript.rows.isEmpty, !didPosition else { return }
        didPosition = true

        // The window this opening is resolved against, pinned before anything below can take the
        // reason for it away. `drawnWindow` moves to hold a search result or an unread mark, and
        // both of those are gone moments from now.
        drawn = Drawn(session: transcript.session.id, window: drawnWindow)
        TranscriptDrawn.note(drawn.window.count)

        // A pane coming back to a session it has already drawn is put back where the reader left
        // it, and none of the three openings below applies: they are all answers to "where should
        // somebody arriving at this conversation start reading", and this reader is not arriving.
        switch TranscriptResume.placement(
            for: memory?.remembered(session: transcript.session.id),
            rowCount: transcript.rows.count
        ) {
        case .liveEnd:
            opening = .liveEnd
        case .offset(let y):
            opening = .offset(y)
        case .row(let seq):
            // At the top of the pane, which is where it was: the anchor IS the row the reader had
            // at the top. Not centred, which is what a search result gets, because a search result
            // is a row somebody is being shown rather than a place somebody is being put back.
            opening = .row(seq, .top)
        case .first:
            // A search result outranks both of the others. Somebody who clicked a line of a
            // transcript in the search screen asked for that line. Centred rather than at the top,
            // because the sentence usually needs the turn around it to make sense.
            // A search result is always a row in a workspace's transcript, because search is
            // over workspaces. A chat with none has nothing to be taken.
            if let workspaceID = transcript.workspace?.id,
               let target = app.takeTranscriptTarget(for: workspaceID) {
                opening = .row(target.seq, .center)
            } else if let unread = transcript.firstUnreadSeq, unread != transcript.rows.first?.seq {
                opening = .row(unread, .top)
            } else {
                opening = .liveEnd
            }
        }
        open(opening)
        Task { await transcript.markAllRead() }
    }

    /// Puts the view where the session was opened.
    ///
    /// **Every one of these says itself twice, and the coordinator does the saying.** The reason
    /// is no longer SwiftUI's: it is that a table scroll resolves against the heights the table
    /// currently believes, and a row that has never been drawn is at the height it was measured
    /// at off screen. The correction arrives one turn later and so does the second attempt. See
    /// `TranscriptTableController.goToEnd` and `Coordinator.scroll(to:anchor:)`.
    private func open(_ opening: Opening?) {
        switch opening {
        case .row(let seq, let anchor):
            controller.scroll(to: .row(seq), anchor: anchor)
        case .liveEnd:
            controller.goToEnd()
        case .offset(let y):
            controller.scroll(toY: y)
        case nil:
            break
        }
    }

    // MARK: - Remembering, and growing

    /// Writes down where the reader is, for the pane to find when it is built again.
    ///
    /// Called when a scroll settles, when a row is folded or unfolded, and when the pane goes
    /// away, rather than on every frame of a scroll. The last of those is the one that cannot be
    /// dropped: a reader who arrives, reads what is on screen and switches tab has scrolled
    /// nothing and folded nothing, and is exactly the case this whole file is about.
    private func remember() {
        // Nothing is written down about a pane that has not drawn anything yet, or has not been
        // laid out yet. The height is what says a layout has happened, and it is checked HERE
        // rather than where the memory is read, because nought is a real place to a reader who is
        // at the top of a conversation.
        guard let target = writingTo, drawn.window.count > 0, geometry.paneHeight > 0 else { return }
        target.memory.remember(
            TranscriptPaneState(
                expanded: expanded,
                offset: contentOffset.value,
                // The row at the top of the pane, which is the place; the offset above is what
                // answers when there is no row to name.
                anchorSeq: topSeq.value > 0 ? topSeq.value : nil,
                isAtLiveEnd: geometry.isNearBottom,
                rowCount: transcript.rows.count,
                drawn: drawn.window
            ),
            session: target.session
        )
    }

    /// Puts the rest of the conversation back, a chunk at a time, below what is drawn.
    ///
    /// The mirror of `growWindow` and much the simpler half. Nothing moves when content is added
    /// under the viewport, so there is no anchor to arrange and no flag to hold.
    private func growWindowDown() {
        guard drawn.session == transcript.session.id,
              drawn.window.canGrowDown(rowCount: transcript.rows.count)
        else { return }
        drawn.window = drawn.window.grownDown(rowCount: transcript.rows.count)
        TranscriptDrawn.note(drawn.window.count)
    }

    /// More history, above what is drawn.
    ///
    /// **No bottom anchor, which is the single clearest win in the move to a table.** Over a lazy
    /// stack this had to hand the scroll view `defaultScrollAnchor(.bottom, for: .sizeChanges)`
    /// for the one update that grew it, because an offset measured from the top of a document that
    /// has just become several hundred rows taller names somewhere else entirely. Here the rows go
    /// in above the reader and the table puts them back on the row they were on. See
    /// `TranscriptAnchor`, where the arithmetic is, and its test, which is that bug written down.
    private func growWindow() {
        // **Only once the session has finished arriving, and this is the whole of why the first
        // build of the window measured worse than no window at all.** A list is at offset nought
        // for the moments between being built and being put on its live end, and offset nought is
        // "near the top" by any definition: measured with `--frame-probe`, the arrival alone grew
        // the window four times and the list ended up holding all 1,582 rows of the session.
        //
        // The live end is checked as well, because a session whose window is shorter than the pane
        // is at its top and its bottom at once, and growing it would add rows above a reader who
        // is reading the newest one. And `isGrowing`, because this is asked on every frame of a
        // scroll that is near the top, and without it the window takes a chunk per frame. That
        // flag is a box rather than `@State` for the reason written where it is declared: clearing
        // it used to cost a rebuild of every entry in the window.
        guard arrivalSession == transcript.session.id,
              !geometry.isNearBottom,
              drawn.session == transcript.session.id,
              drawn.window.canGrowUp,
              !isGrowing.value
        else { return }
        isGrowing.value = true
        drawn.window = drawn.window.grownUp()
        TranscriptDrawn.note(drawn.window.count)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            isGrowing.value = false
        }
    }

    // MARK: - Arrivals

    /// Takes the list in and works out what is new about it, unless the session is still arriving.
    ///
    /// The ids are plain sequence numbers rather than anything session scoped, because `adopt`
    /// replaces the tracker's whole idea of the list every time a session loads. A seq that means
    /// one row in one session and a different row in the next can never be compared against the
    /// wrong one.
    private func trackArrivals() {
        let seqs = transcript.rows.suffix(TranscriptArrivals.window).map(\.seq)
        guard arrivalSession == transcript.session.id else {
            arrivals.adopt(seqs)
            return
        }
        arrivals.absorb(seqs)
    }

    private func toggle(_ seq: Int) {
        // **The height a fold changes is the table's, not the row's**, so the travel cannot be a
        // `withAnimation` around this mutation the way it was over a lazy stack: there, the
        // animation carried into the `if` inside `ToolRowView` and the row grew itself. Here the
        // row is remeasured and the table is told a number. So the table is warned that the next
        // height change on this row is one the reader asked for, and it animates that one and
        // nothing else. See `TranscriptTable.Coordinator.willUnfold`.
        controller.willUnfold(.row(seq))
        if expanded.contains(seq) {
            expanded.remove(seq)
        } else {
            expanded.insert(seq)
        }
        // Written down straight away rather than left to the next settled scroll, because
        // unfolding a tool result and switching tab to look at what it did is one gesture, and
        // re-folding it behind the reader's back was the bug. See `TranscriptResume`.
        remember()
    }
}
