import AppKit
import BloomCore
import SwiftUI

/// The table's half of `TranscriptListView`. **Spike.**
///
/// It is deliberately the same shape as the lazy stack's version and a good deal shorter, because
/// everything the stack has to do to keep a reader's place is done for it here: the window is the
/// same `TranscriptWindow`, the memory is the same `TranscriptPaneState`, and the rows handed to
/// the table are exactly the rows the stack would have been handed, so the two can be measured
/// against each other on the same session.
///
/// What is not here, and is not an accident: the arrival fades, the `.equatable()` row comparison
/// (the table recycles on a content key instead), the two-call dance every scroll needed because
/// `ScrollPosition` is a value, and the growth anchor, because a table can be told to put a row
/// back where it was rather than a point.
struct TranscriptTableListView: View {
    let transcript: TranscriptModel
    var isRunningSetup: Bool = false
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

    @State private var expanded: Set<Int> = []
    @State private var geometry = TranscriptGeometry()
    @State private var bubbleWidth = TranscriptBubbleWidth()
    @State private var hoverHost = TranscriptHoverHost()
    @State private var didPosition = false
    @State private var showsSetup = false
    @State private var isGrowing = false
    @State private var resumed: SessionID?
    @State private var opening: Opening?
    @State private var writingTo: WriteTarget?
    @State private var contentOffset = GeometryBox(0.0)
    @State private var reachToEnd = GeometryBox(0.0)
    /// The row at the top of the pane, kept out of `@State` for the reason `TranscriptVisibleRows`
    /// is: it moves on every frame of a scroll and nothing draws from it.
    @State private var topSeq = GeometryBox(0)

    @State private var controller = TranscriptTableController()
    @State private var scroller = TranscriptLiveEndScroller()
    @State private var follower = TranscriptLiveEndFollower()
    @State private var catchUp: Task<Void, Never>?

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.fontScale) private var fontScale

    private struct Drawn: Equatable {
        var session: SessionID
        var window: TranscriptWindow
    }

    @State private var drawn: Drawn

    private struct WriteTarget {
        var memory: TranscriptPaneMemory
        var session: SessionID
    }

    private enum Opening: Equatable {
        case liveEnd
        case row(Int, UnitPoint)
        case offset(Double)
    }

    private static let bubbleShare: CGFloat = 0.7
    private static let bubbleFloor: CGFloat = 240

    // MARK: - The rows

    private var visibleRows: ArraySlice<TranscriptRow> {
        let window = drawnWindow
        return transcript.rows[window.start..<window.end]
    }

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

    private var mustReachIndex: Int? {
        let seqs = transcript.rows.lazy.map(\.seq)
        if let target = app.pendingTranscriptTarget,
           target.workspaceID == transcript.workspace.id {
            return TranscriptWindow.index(ofSeqAtOrAfter: target.seq, in: seqs)
        }
        if let unread = transcript.firstUnreadSeq {
            return TranscriptWindow.index(ofSeqAtOrAfter: unread, in: seqs)
        }
        return nil
    }

    private var linkActions: TranscriptLinkActions {
        TranscriptLink.actions(
            for: app.existingModel(for: transcript.workspace.id), pane: memory?.pane
        )
    }

    private var showsPlaceholder: Bool {
        transcript.isLoaded
            && !transcript.isRunning
            && !showsSetup
            && transcript.hasNothingToShow
            && !transcript.isStreaming
    }

    private static func rowID(_ seq: Int) -> String { "row.\(seq)" }

    /// Everything the table draws, in order.
    ///
    /// Assembled on every pass over this body, which is what the lazy stack's `ForEach` was doing
    /// too. Nothing is BUILT here: each entry carries a closure the table calls when it measures or
    /// draws the row, so a session of four thousand rows costs four thousand closures rather than
    /// four thousand views.
    private var entries: [TranscriptTableEntry] {
        let workspace = transcript.workspace
        let projectName = transcript.projectName
        let rows = transcript.rows
        let permissionMode = transcript.session.permissionMode
        let recoveredRuns = transcript.recoveredRuns
        let stoppedTurnSeq = transcript.stoppedTurnSeq
        let paneHeight = geometry.paneHeight

        var out: [TranscriptTableEntry] = []
        out.append(TranscriptTableEntry(
            id: "setup",
            contentKey: "setup.\(workspace.id).\(isRunningSetup).\(transcript.hasNothingToShow).\(Int(paneHeight))",
            // A setup script prints while it runs, and nothing in this body is told when it does.
            isLive: isRunningSetup,
            content: {
                AnyView(
                    WorkspaceEventsView(
                        workspaceID: workspace.id,
                        isRunning: isRunningSetup,
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

        for row in visibleRows where !TranscriptNoise.isHidden(row) {
            let isExpanded = expanded.contains(row.seq)
            let wasStopped = row.seq == stoppedTurnSeq
            let recovered = recoveredRuns[row.seq]
            // The same fields `TranscriptRowView.==` compares, and for the same reason: the
            // payload is never read, because comparing it is 1.6MB of `Data` per pass.
            let key = [
                "\(row.id)", "\(row.seq)", row.kind.rawValue, "\(row.isError)",
                "\(row.durationMS ?? -1)", "\(row.resultPayload?.count ?? -1)",
                row.permissionDecision ?? "", row.permissionNote, "\(isExpanded)",
                row.parentToolUseID ?? "", "\(wasStopped)", "\(recovered != nil)",
            ].joined(separator: "|")

            if row.kind == .result {
                out.append(TranscriptTableEntry(
                    id: Self.rowID(row.seq), contentKey: key, isLive: false,
                    content: {
                        AnyView(
                            TurnFooterView(
                                rows: rows,
                                row: row,
                                worktree: workspace.path,
                                permissionMode: permissionMode,
                                wasStopped: wasStopped,
                                recovered: recovered
                            )
                            .padding(.horizontal, TranscriptLayout.inset)
                            .padding(.bottom, TranscriptLayout.turnGap)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        )
                    }
                ))
            } else {
                out.append(TranscriptTableEntry(
                    id: Self.rowID(row.seq), contentKey: key, isLive: false,
                    content: {
                        AnyView(
                            TranscriptRowView(
                                row: row,
                                workspace: workspace,
                                isExpanded: isExpanded,
                                isNested: row.parentToolUseID != nil,
                                projectName: projectName,
                                onToggle: { toggle(row.seq) },
                                onAnswer: { requestID, decision in
                                    Task { await transcript.answer(requestID: requestID, decision: decision) }
                                }
                            )
                            .padding(.horizontal, TranscriptLayout.inset)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        )
                    }
                ))
            }
        }

        if let sending = transcript.sending {
            out.append(TranscriptTableEntry(
                id: "sending", contentKey: "sending.\(sending.id)", isLive: false,
                content: {
                    let review = ReviewTurn.split(sending.body)
                    let turn = AttachmentTrailer.split(sending.body)
                    return AnyView(
                        Group {
                            if let review {
                                UserTurnRowView(
                                    text: review.message, reviewChips: review.chips, workspace: workspace
                                )
                            } else {
                                UserTurnRowView(
                                    text: turn.body, attachments: turn.paths, workspace: workspace
                                )
                            }
                        }
                        .padding(.horizontal, TranscriptLayout.inset)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    )
                }
            ))
        }

        // The one entry that changes height without anything telling this view so. See `isLive`.
        out.append(TranscriptTableEntry(
            id: "streaming", contentKey: "streaming", isLive: true,
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

        for delivery in transcript.waitingDeliveries {
            let isLast = delivery.id == transcript.waitingDeliveries.last?.id
            let hold = isLast ? transcript.deliveryHold : nil
            out.append(TranscriptTableEntry(
                id: "pending.\(delivery.id)",
                contentKey: "pending.\(delivery.id).\(isLast)",
                isLive: isLast,
                content: {
                    AnyView(
                        PendingTurnRowView(
                            delivery: delivery,
                            hold: hold,
                            onDelete: { transcript.askToDiscard(delivery) }
                        )
                        .padding(.horizontal, TranscriptLayout.inset)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    )
                }
            ))
        }
        return out
    }

    // MARK: - Body

    var body: some View {
        let _ = SwitchTrace.mark("transcript.body", workspace: transcript.workspace.id)
        let _ = SwitchTrace.markOnScreen("transcript.body", workspace: transcript.workspace.id)
        @Bindable var transcript = transcript

        TranscriptTable(
            entries: entries,
            controller: controller,
            scale: fontScale,
            onGeometryChange: { measured($0) },
            onSettled: { remember() },
            onScrollStarted: {
                hoverHost.request = nil
                scroller.stop()
                catchUp?.cancel()
            }
        )
        .environment(\.transcriptHoverHost, hoverHost)
        .environment(\.transcriptBubbleWidth, bubbleWidth)
        .markdownLinkActions(linkActions)
        .overlay { TranscriptHoverOverlay(host: hoverHost) }
        .overlay {
            if showsPlaceholder {
                TranscriptPlaceholderView(isRunningSetup: isRunningSetup)
            }
        }
        .onDisappear { remember() }
        .onChange(of: transcript.rows.count, initial: true) { _, _ in
            position()
            growWindowDown()
            follower.nudge()
        }
        .onChange(of: transcript.isStreaming, initial: true) { _, streaming in
            follower.isStreaming = streaming
        }
        .onChange(of: activeState, initial: true) { _, state in
            follower.isFrontmost = state != .inactive
        }
        .onChange(of: reduceMotion, initial: true) { _, reduced in
            follower.travels = TranscriptFollow.travels(reduceMotion: reduced)
        }
        .onChange(of: transcript.liveEndRequests) { _, _ in
            goToLiveEnd()
        }
        .onChange(of: transcript.session.id) { _, _ in
            remember()
            scroller.stop()
            follower.stop()
            catchUp?.cancel()
            didPosition = false
            opening = nil
            let remembered = memory?.remembered(session: transcript.session.id)
            expanded = remembered?.expanded ?? []
            geometry.isNearBottom = true
            geometry.isFarFromEnd = false
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
            topSeq.value = 0
        }
        .task(id: transcript.session.id) {
            // The two hand-backs the SwiftUI list owes `ScrollPosition` have nothing to hand back
            // to here: an AppKit scroll view has no standing instruction to be taken off and put
            // back, so the follower simply drives the clip view and nothing argues with it.
            follower.onRest = nil
            follower.onStart = nil
            await transcript.load()
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
            didPosition = false
            await Task.yield()
            guard !Task.isCancelled else { return }
            adoptScrollView()
            position()

            guard resumed != transcript.session.id else {
                SwitchTrace.mark("transcript.window", workspace: transcript.workspace.id)
                SwitchTrace.markOnScreen("transcript.window", workspace: transcript.workspace.id)
                return
            }

            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            let settled = TranscriptWindow.settling(
                from: drawn.window, rowCount: transcript.rows.count
            )
            drawn = Drawn(session: transcript.session.id, window: settled)
            TranscriptDrawn.note(settled.count)
            SwitchTrace.mark("transcript.window", workspace: transcript.workspace.id)
            SwitchTrace.markOnScreen("transcript.window", workspace: transcript.workspace.id)
            follower.forget()
            // The history goes in ABOVE the viewport, and the table puts the reader back on the
            // row they were on rather than at the point they were at, so there is nothing here to
            // undo. The lazy stack needed two scrolls and a comment three times this long.
            await Task.yield()
            guard !Task.isCancelled else { return }
            open(opening)
            SwitchTrace.mark("transcript.history", workspace: transcript.workspace.id)
            SwitchTrace.markOnScreen("transcript.history", workspace: transcript.workspace.id)
        }
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

        bubbleWidth.cap = TranscriptGeometry.cap(
            width: table.viewportWidth,
            share: Self.bubbleShare,
            gutter: Metrics.gutter,
            floor: Self.bubbleFloor
        )
        reachToEnd.value = TranscriptGeometry.reach(
            contentHeight: table.contentHeight,
            viewportHeight: table.viewportHeight,
            offset: table.offset
        )
        contentOffset.value = table.offset
        if let id = controller.topmostEntryID, let seq = Self.seq(ofEntry: id) {
            topSeq.value = seq
        }

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
        // The end of what is drawn is not the end of the conversation. See `TranscriptListView`.
        if drawn.session == transcript.session.id,
           drawn.window.canGrowDown(rowCount: transcript.rows.count) {
            measured.isNearBottom = false
            measured.isFarFromEnd = true
        }
        // Written only on a change, because this runs on every frame of every scroll and each
        // write is a pass over this body. The report to the composer goes with it: the lazy stack
        // gets one per change of a quantised projection, and one per frame would put the jump
        // pill's state write on the scroll path.
        if measured != geometry {
            geometry = measured
            onScrolledUpChange?(measured.isFarFromEnd)
        }

        if table.offset < table.viewportHeight { growWindow() }
        if measured.isNearBottom || table.contentHeight - table.viewportHeight - table.offset < 1 {
            growWindowDown()
        }
    }

    private static func seq(ofEntry id: String) -> Int? {
        guard id.hasPrefix("row.") else { return nil }
        return Int(id.dropFirst(4))
    }

    /// Hands the glide and the follower the scroll view the table is in.
    ///
    /// This is what `TranscriptScrollBridge` was for. There is no walking up from a planted view
    /// any more: the table owns its `NSScrollView` and simply says which one it is.
    private func adoptScrollView() {
        let found = controller.scrollView
        if scroller.scrollView !== found { scroller.scrollView = found }
        if follower.scrollView !== found { follower.scrollView = found }
    }

    // MARK: - Scrolling

    private func showSetupLogEnd(wasAsked: Bool) {
        guard transcript.rows.isEmpty else {
            if wasAsked { controller.scroll(to: "setup", anchor: .bottom) }
            return
        }
        guard wasAsked || geometry.isNearBottom else { return }
        controller.scrollToEnd()
    }

    private func goToLiveEnd() {
        catchUp?.cancel()
        if drawn.session == transcript.session.id,
           drawn.window.canGrowDown(rowCount: transcript.rows.count) {
            drawn.window = TranscriptWindow.liveEnd(rowCount: transcript.rows.count)
            TranscriptDrawn.note(drawn.window.count)
        }
        let move = TranscriptMotion.liveEndMove(
            distance: reachToEnd.value, reduceMotion: reduceMotion
        )
        switch move {
        case .jump:
            controller.scrollToEnd()
        case .glide(let seconds):
            guard scroller.glide(seconds: seconds, completion: { controller.scrollToEnd() }) else {
                controller.scrollToEnd()
                return
            }
        }
        guard TranscriptMotion.reassertsLiveEnd(after: move, isStreaming: transcript.isStreaming),
              case .glide(let seconds) = move else { return }
        catchUp = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds + 0.05))
            guard !Task.isCancelled else { return }
            controller.scrollToEnd()
        }
    }

    private func position() {
        guard !transcript.rows.isEmpty, !didPosition else { return }
        didPosition = true
        drawn = Drawn(session: transcript.session.id, window: drawnWindow)
        TranscriptDrawn.note(drawn.window.count)

        switch TranscriptResume.placement(
            for: memory?.remembered(session: transcript.session.id),
            rowCount: transcript.rows.count
        ) {
        case .liveEnd:
            opening = .liveEnd
        case .offset(let y):
            opening = .offset(y)
        case .row(let seq):
            opening = .row(seq, .top)
        case .first:
            if let target = app.takeTranscriptTarget(for: transcript.workspace.id) {
                opening = .row(target.seq, .center)
            } else if let unread = transcript.firstUnreadSeq, unread != transcript.rows.first?.seq {
                opening = .row(unread, .top)
            } else {
                opening = .liveEnd
            }
        }
        // One call rather than the stack's two, because a table scroll is a call on a view that
        // already knows every row's height: there is no pass to wait for and no standing value to
        // argue with. The second is still made, once, for the case where the window this opening
        // names has only just been handed over.
        open(opening)
        let settled = opening
        Task { @MainActor in
            await Task.yield()
            open(settled)
        }
        Task { await transcript.markAllRead() }
    }

    private func open(_ opening: Opening?) {
        switch opening {
        case .row(let seq, let anchor):
            controller.scroll(to: Self.rowID(seq), anchor: anchor)
        case .liveEnd:
            controller.scrollToEnd()
        case .offset(let y):
            controller.scroll(toY: y)
        case nil:
            break
        }
    }

    // MARK: - Remembering, and growing

    private func remember() {
        guard let target = writingTo, drawn.window.count > 0, geometry.paneHeight > 0 else { return }
        target.memory.remember(
            TranscriptPaneState(
                expanded: expanded,
                offset: contentOffset.value,
                anchorSeq: topSeq.value > 0 ? topSeq.value : nil,
                isAtLiveEnd: geometry.isNearBottom,
                rowCount: transcript.rows.count,
                drawn: drawn.window
            ),
            session: target.session
        )
    }

    private func growWindowDown() {
        guard drawn.session == transcript.session.id,
              drawn.window.canGrowDown(rowCount: transcript.rows.count)
        else { return }
        drawn.window = drawn.window.grownDown(rowCount: transcript.rows.count)
        TranscriptDrawn.note(drawn.window.count)
    }

    /// More history, above what is drawn.
    ///
    /// No `isGrowing` flag and no bottom anchor. The rows go in above the reader and the table
    /// puts them back on the row they were on, which is `TranscriptTable`'s anchoring and is the
    /// single clearest win in this spike.
    private func growWindow() {
        // `isGrowing` for the reason the lazy stack has one: this is asked on every frame of a
        // scroll that is near the top, and without it the window takes a chunk per frame and the
        // whole history is in the list a fifth of a second later.
        guard didPosition,
              !geometry.isNearBottom,
              drawn.session == transcript.session.id,
              drawn.window.canGrowUp,
              !isGrowing
        else { return }
        isGrowing = true
        drawn.window = drawn.window.grownUp()
        TranscriptDrawn.note(drawn.window.count)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            isGrowing = false
        }
    }

    private func toggle(_ seq: Int) {
        // Unanimated, because the height a fold changes is the table's and not the row's: the row
        // is remeasured on the next pass and the table is told the new number. There is no
        // transition to carry. See the report.
        if expanded.contains(seq) {
            expanded.remove(seq)
        } else {
            expanded.insert(seq)
        }
        remember()
    }
}
