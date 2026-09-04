import AppKit
import BloomCore
import QuartzCore
import SwiftUI

/// The transcript, drawn by an `NSTableView`.
///
/// **Why not a `LazyVStack`, which is what this replaced.** SwiftUI cannot be told how tall an
/// unrealised row is, so it guesses for every row it has not built. Measured on an 1,855 message
/// session, the content height fell from 48,995 points to 17,339 during a single scroll pass, and
/// a reader's place could not be put back because the offset it was written down against no longer
/// named the same row. Table against stack, twice each on an idle machine: 13.6 frames a second on
/// a resize against 6.6 to 11.4, 110ms of main thread per second of streaming against 275, and a
/// reader put back where they were on four returns out of four where the stack returned them to
/// the top of the conversation every time.
///
/// **The bargain:** the table has to be TOLD each height, and the only thing that knows a SwiftUI
/// row's height is a laid out `NSHostingView`. So heights are measured off screen, one per row per
/// width, and cached by `TranscriptRowHeights` in the core. That cost falls whenever the table is
/// reloaded and whenever the pane's width changes, which are the two moments the lazy stack was
/// cheapest. A resize therefore holds the whole table still rather than paying it per frame: see
/// `TranscriptHoldView`, and `rewidth` below for what is measured when the hand comes off.
struct TranscriptTableEntry: Identifiable {
    /// Stable across passes. See `TranscriptEntryID` for why it is a type rather than a string.
    let id: TranscriptEntryID
    /// Everything about the entry that can change what it draws, and therefore how tall it is.
    /// The height cache is keyed on this, so a row whose key has not moved is never remeasured and
    /// a cell holding it is never rebuilt.
    ///
    /// **The three entries that re-render from their own observation are not excepted, and used to
    /// be.** The streaming tail, the setup log and the delivery at the head of the queue watch
    /// their own state and redraw inside the cell they are in; handing them a new root view on
    /// every pass threw that state away and rebuilt the tail several times a second.
    let contentKey: TranscriptContentKey
    /// Whether this entry is expected to draw nothing at all, which most of a session is. An
    /// unmeasured row that says so is told nought rather than the running mean: see
    /// `TranscriptRowInk`, which decides it, and `TranscriptRowHeights.assumed`, which uses it.
    ///
    /// False for the four entries that are not stored rows. Each of them draws nothing much of the
    /// time, and each is on screen at the live end where it is measured immediately anyway, so a
    /// claim about them would buy nothing and could be wrong about the streaming tail, which is the
    /// one entry that changes height without anything saying so.
    var drawsNothing = false
    /// Which cluster of row heights this entry belongs to, which is what an unmeasured one is
    /// drawn at until somebody looks at it. See `TranscriptRowShape`, which carries the white gaps
    /// a single conversation-wide mean left on the way up.
    var shape: TranscriptRowShape = .other
    /// Built on demand: when the row is measured, and when it is drawn. Nothing is built for a row
    /// that is neither, which is what keeps the pass that assembles these cheap.
    let content: @MainActor () -> AnyView
}

/// What the scroll view is telling the transcript, in the shape `ScrollGeometry` had.
struct TranscriptTableGeometry: Equatable {
    var offset: CGFloat = 0
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0
    var viewportWidth: CGFloat = 0

    /// Exactly at the end rather than near it. See `TranscriptAnchor.isAtEnd`.
    var isAtEnd: Bool {
        TranscriptAnchor.isAtEnd(
            offset: offset, contentHeight: contentHeight, viewportHeight: viewportHeight
        )
    }
}

/// The handle the pane keeps on the table, for the four things it has to be able to do to it: go
/// to the end and stay there, stop staying there, go to a row by name, and go to a point.
@MainActor
final class TranscriptTableController {
    fileprivate weak var coordinator: TranscriptTable.Coordinator?

    var scrollView: NSScrollView? { coordinator?.scrollView }

    /// **Go to the end of the conversation, and keep being at it until somebody says otherwise.**
    ///
    /// A single `setBoundsOrigin` is a movement, and a movement is short of the end the moment
    /// anything below it changes size, which in a transcript is constantly: heights are corrected
    /// after a row is drawn, the streaming tail grows between rows, and a window just moved to the
    /// tail has not been laid out when the scroll is issued. So the instruction is held: every
    /// place in the coordinator that can change where the end is re-asserts it, and `releaseEnd`
    /// or the reader taking hold of the view lets it go. See `Coordinator.holdsEnd`.
    func goToEnd() { coordinator?.goToEnd() }

    /// Lets go of the standing instruction above, without moving anything.
    func releaseEnd() { coordinator?.releaseEnd() }

    /// Whether that instruction is standing now. Read by the pane when it writes down where the
    /// reader was: an instruction to be at the end is where somebody is, even on the frames a
    /// height correction has left the view a few points short of it.
    var holdsEnd: Bool { coordinator?.holdsEnd ?? false }

    /// **`TranscriptLiveEndFollower` is driving the clip view from here on, so nothing in the
    /// table may touch it.**
    ///
    /// Both moving the view at the live end is the two of them fighting, one at 120Hz and one per
    /// height correction, and what reaches the screen is the instant pin with the travel invisible
    /// underneath it. The follower is the only one that can make a movement the eye can read, so
    /// it wins for as long as it is running.
    func followerTookOver() -> Bool { coordinator?.followerTookOver() ?? false }

    /// The follower's link has gone down, wherever it left the view. See
    /// `TranscriptLiveEndFollower.onStop`, which carries why this cannot be `onRest`.
    func followerHandedBack() { coordinator?.followerHandedBack() }

    func scroll(to entryID: TranscriptEntryID, anchor: UnitPoint) {
        coordinator?.scroll(to: entryID, anchor: anchor)
    }

    /// Put this row back this far above the top of the pane, which is where a reader who was part
    /// way down a long answer left it. See `TranscriptAnchor.offset(rowTop:delta:)`.
    func scroll(to entryID: TranscriptEntryID, delta: CGFloat) {
        coordinator?.scroll(to: entryID, delta: delta)
    }

    func scroll(toY y: CGFloat) { coordinator?.scroll(toY: y) }

    /// A fold is about to open or close. See `Coordinator.pendingUnfolds`.
    func willUnfold(_ entryID: TranscriptEntryID) { coordinator?.willUnfold(entryID) }

    /// A transcript activity group is about to add or remove its disclosed rows.
    func willChangeFoldRows(_ entryID: TranscriptEntryID) {
        coordinator?.willChangeFoldRows(entryID)
    }

    /// **The conversation this pane was pointed at is in, and in the place the reader left it.**
    ///
    /// Said by the pane rather than worked out here, because the only thing that knows a
    /// transcript is where it belongs is whatever put it there: the rows have loaded, the window
    /// has been chosen and `TranscriptResume`'s placement has been applied. Until this arrives the
    /// pane draws nothing. See `TranscriptHoldView.hold(_:)`.
    func arrived() { coordinator?.arrived() }

    /// Where the reader is, as the pair that puts them back: the stored row at the top of the
    /// pane, and how far above its own top the pane starts. See `Coordinator.topmostPlace`.
    var topmostPlace: (seq: Int, delta: CGFloat)? { coordinator?.topmostPlace }

    /// Whether the whole entry is above the viewport. Nil when it is outside the drawn window.
    func isAboveViewport(_ entryID: TranscriptEntryID) -> Bool? {
        coordinator?.isAboveViewport(entryID)
    }

    var geometry: TranscriptTableGeometry {
        coordinator?.currentGeometry ?? TranscriptTableGeometry()
    }
}

/// The transcript's scroll view, which differs from `NSScrollView` in exactly one answer.
///
/// **A markdown table stopped the transcript scrolling under the pointer.** A table and a code
/// fence each sit in a `ScrollView(.horizontal)` of their own, and an inner scroll view already at
/// its edge keeps the wheel and rubber-bands unless a responder above it has asked to be forwarded
/// one. `wantsForwardedScrollEvents(for:)` is false by default, so nothing asked and the
/// transcript stood still.
///
/// Asking is the whole fix, and it covers tables and code fences alike. AppKit forwards only from
/// an inner view at its edge in that axis and decides the predominant axis itself, so a wide table
/// still scrolls sideways.
final class TranscriptScrollView: NSScrollView {
    override func wantsForwardedScrollEvents(for axis: NSEvent.GestureAxis) -> Bool {
        axis == .vertical
    }
}

struct TranscriptTable: NSViewRepresentable {
    let entries: [TranscriptTableEntry]
    /// Which conversation these entries are. A pane is handed a different one by every workspace
    /// switch, and what it draws until that one is ready is nothing at all: see
    /// `TranscriptHoldView.hold(_:)`.
    let session: SessionID
    let controller: TranscriptTableController
    /// The text scale the rows are drawn at. Part of what the height cache is keyed on, because
    /// the same row at a different scale is a different height.
    let scale: CGFloat
    /// Exactly what a hosted row needs from the environment and nothing else. See
    /// `TranscriptRowEnvironment`, which carries why this is a named list rather than `\.self`.
    let rowEnvironment: TranscriptRowEnvironment
    let onGeometryChange: @MainActor (TranscriptTableGeometry) -> Void
    /// A scroll has stopped moving. Where the pane writes down where the reader is.
    let onSettled: @MainActor () -> Void
    /// **The reader has taken hold of the view, or let go of it.** True on the first frame of a
    /// gesture and false when it ends.
    ///
    /// Not a debounce over "the clip view moved", which cannot tell a hand from this app's own
    /// travel: the jump pill's glide reported itself as a scroll on its first frame and the pane's
    /// handler stopped it, leaving the transcript a few points down with the completion never run.
    /// `NSScrollView` posts `willStartLiveScroll` and `didEndLiveScroll` for user-initiated
    /// scrolling only, so this app's own movement is silent here.
    let onLiveScrollChange: @MainActor (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TranscriptHoldView {
        let table = NSTableView()
        table.headerView = nil
        table.style = .plain
        table.rowSizeStyle = .custom
        table.usesAutomaticRowHeights = false
        table.usesAlternatingRowBackgroundColors = false
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.gridStyleMask = []
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("transcript"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        table.dataSource = context.coordinator
        table.delegate = context.coordinator

        let scroll = TranscriptScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.automaticallyAdjustsContentInsets = false
        // **No content insets, and the lazy stack's `.padding(.vertical, TranscriptLayout.block)`
        // is therefore missing.** An inset moves the end of the scrollable range away from
        // `document.height - clip.height`, which is the number this file, the glide and the
        // follower all use for "the end", and three places disagreeing about where the end is is a
        // worse bug than a transcript with no air above its first row. The padding is on the first
        // and last entries instead: see the setup and streaming entries in `TranscriptListView`.
        scroll.contentInsets = .init()

        context.coordinator.attach(table: table, scroll: scroll)
        controller.coordinator = context.coordinator

        // The scroll view is not this representable's view any more. See `TranscriptHoldView`,
        // which keeps it at the width it was laid out at while a pane is being dragged.
        let hold = TranscriptHoldView(scroll: scroll)
        hold.delegate = context.coordinator
        context.coordinator.holdView = hold
        return hold
    }

    /// Whatever the pane offers, which is what the scroll view took before it was wrapped. A plain
    /// `NSView` has no intrinsic size for SwiftUI to fall back on.
    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: TranscriptHoldView, context: Context
    ) -> CGSize? {
        CGSize(
            width: proposal.width ?? nsView.bounds.width,
            height: proposal.height ?? nsView.bounds.height
        )
    }

    func updateNSView(_ nsView: TranscriptHoldView, context: Context) {
        let coordinator = context.coordinator
        controller.coordinator = coordinator
        coordinator.onGeometry = onGeometryChange
        coordinator.onSettled = onSettled
        coordinator.onLiveScrollChange = onLiveScrollChange
        // Before the entries, so that a pass carrying another conversation's rows is applied to a
        // pane that has already stopped drawing.
        coordinator.showing(session: session, in: nsView)
        coordinator.apply(entries: entries, scale: scale, environment: rowEnvironment)
    }

    // MARK: - The coordinator

    @MainActor
    final class Coordinator:
        NSObject, NSTableViewDataSource, NSTableViewDelegate, TranscriptHoldDelegate {
        private(set) var entries: [TranscriptTableEntry] = []
        private var ids: [TranscriptEntryID] = []
        private var index: [TranscriptEntryID: Int] = [:]
        private var rowEnvironment: TranscriptRowEnvironment?
        var onGeometry: (@MainActor (TranscriptTableGeometry) -> Void)?
        var onSettled: (@MainActor () -> Void)?
        var onLiveScrollChange: (@MainActor (Bool) -> Void)?

        weak var tableView: NSTableView?
        weak var scrollView: NSScrollView?

        /// Height by content key, at one width and one text size.
        ///
        /// Never emptied by a reload, which is the whole point: the document is the same height
        /// after a row lands as it was before, so nothing under the reader moves, and the number a
        /// reader's place was written down against still means something. See
        /// `TranscriptRowHeights`.
        private var heights = TranscriptRowHeights()
        private var settleWork: Task<Void, Never>?
        /// Preparing the rows just above the screen while nobody is moving. See `warmAhead`.
        private var warmWork: Task<Void, Never>?
        /// A reflow saying its placement a second time. See `rewidth`.
        private var placeWork: Task<Void, Never>?
        private var resizeWork: Task<Void, Never>?
        private var endWork: Task<Void, Never>?
        private var reaimWork: Task<Void, Never>?
        /// Rows whose height turned out to be wrong once they were drawn, batched so a pass over
        /// the visible rows costs one `noteHeightOfRows` rather than one each.
        ///
        /// **By id, and it was by row index.** The batch is drained a turn after it is filled, and
        /// a pass in between renumbers every row: an arrival draws the tail and puts the history
        /// in above it a frame later, which moved every index in here by seventeen hundred. The
        /// table was then told that seventeen hundred estimates had changed, and the rows that had
        /// actually reported were never told again. See `noted`.
        private var owedHeights: Set<TranscriptEntryID> = []
        private var owedWork: Task<Void, Never>?

        /// **A standing instruction to be at the end of the conversation.** See
        /// `TranscriptTableController.goToEnd`, which carries why a single scroll cannot mean it.
        ///
        /// Readable through the controller, because the pane has to write down whether the reader
        /// was at the live end and an instruction to be there is where somebody is. Written here
        /// and nowhere else: `goToEnd` and `releaseEnd` are the only two things that move it.
        fileprivate private(set) var holdsEnd = false
        /// A pane reflow that began at the end is not a user scroll. AppKit can deliver the
        /// bounds changes caused by its row-height corrections after `noteHeightOfRows` returns,
        /// so `isPutting` alone cannot distinguish them from a wheel event. Keep that distinction
        /// until the resized table has been quiet and has reached its new end once.
        private var isSettlingResizeAtEnd = false
        /// Whether this file is the thing moving the clip view right now, so that the escape below
        /// does not read the transcript's own arrival at the end as the reader scrolling away.
        private var isPutting = false
        /// Whether the reader has hold of the view. `NSScrollView`'s own answer, not a guess.
        private var isLiveScrolling = false
        /// When the last step of a live scroll arrived, so a gesture nothing announced the start
        /// or the end of can be noticed to have stopped. See `liveScrolled`.
        private var lastLiveScroll: CFTimeInterval = 0
        private var quietWork: Task<Void, Never>?
        /// Whether the follower is driving. See `TranscriptTableController.followerTookOver`.
        private var isFollowerDriving = false
        /// Rows whose next height change is a fold the reader just clicked, and may therefore be
        /// animated. Consumed by the pass that applies it. See `willUnfold`.
        private var pendingUnfolds: Set<TranscriptEntryID> = []
        /// The next row-list change came from a disclosure click rather than from live activity.
        /// Only that change gets the brief cross-fade requested for opening and closing a group.
        private var pendingFoldRows = false
        /// The disclosure row where the reader clicked, held at the same point in the viewport
        /// while its children enter or leave below it.
        private var pendingFoldAnchor: (id: TranscriptEntryID, delta: CGFloat)?

        /// **Whether the transcript is being held still while a pane is resized.** Nothing in here
        /// measures, reloads or moves while it is on. See `TranscriptHoldView`.
        private var isHeld = false
        /// The last pass that arrived while the transcript was held, applied when it is let go.
        /// Rows that land mid drag are held with everything else and turn up in the same fade.
        private var whileHeld:
            (entries: [TranscriptTableEntry], scale: CGFloat, environment: TranscriptRowEnvironment)?

        /// Where the reader was when a hold began, which is where they still are: nothing under
        /// them moves while it is on. See `holdBegan`.
        private struct HeldPlace {
            var wasAtEnd: Bool
            var anchor: (id: TranscriptEntryID, delta: CGFloat)?
        }
        private var heldPlace: HeldPlace?

        /// The conversation this pane is currently drawing. A change of it is an arrival, and an
        /// arrival is not drawn until it is ready. See `showing(session:in:)`.
        private var shownSession: SessionID?
        /// **What makes a cell rebuild even when its content key has not moved.**
        ///
        /// A cell recycles on its content key, which is the whole of what a table buys over a
        /// stack, and twice that is not enough. A pool holds cells from the conversation the pane
        /// has left, keyed by ids that are singletons across sessions (`.setup`, `.sending`,
        /// `.streaming`), so coming back to a conversation can hand a row the very cell it had
        /// last time: `apply` sees the key it already holds, returns, and the cell goes on hosting
        /// a row built from the OTHER session's model, which is still running and still growing.
        /// Its height reports are filed under this session's key, because the ids carry no session
        /// to tell them apart, and the gap that opens is under the newest row.
        ///
        /// The second is the environment. `apply` reloads the table when the environment moves,
        /// on the argument that every cell holds values from the one it was built in, and the key
        /// guard silently defeated it: a reload re-asks for views and the pool hands the same
        /// cells straight back, still carrying the pane a link opens into from the workspace
        /// before last.
        ///
        /// Bumped rather than cleared per cell, because there is no reaching into an
        /// `NSTableView`'s reuse pool: a number the cells carry is the only way to say "whatever
        /// you are holding is from before".
        private var cellGeneration = 0
        weak var holdView: TranscriptHoldView?

        /// The width a row is actually drawn at, which is the TABLE's width and not the clip
        /// view's.
        ///
        /// **This was half of the wrong heights.** With legacy scrollers the clip view is fifteen
        /// points wider than the document inside it, so a paragraph measured at the clip's width
        /// wraps to fewer lines than it draws at and the row comes out short with its first line
        /// clipped off the top. One column and no intercell spacing, so the table's width is the
        /// cell's width.
        private var columnWidth: CGFloat {
            if let tableView, tableView.bounds.width > 1 { return tableView.bounds.width }
            return scrollView?.contentView.bounds.width ?? 0
        }

        func attach(table: NSTableView, scroll: NSScrollView) {
            tableView = table
            scrollView = scroll
            scroll.contentView.postsBoundsChangedNotifications = true
            scroll.postsFrameChangedNotifications = true
            let centre = NotificationCenter.default
            centre.addObserver(
                self, selector: #selector(clipMoved),
                name: NSView.boundsDidChangeNotification, object: scroll.contentView
            )
            centre.addObserver(
                self, selector: #selector(paneResized),
                name: NSView.frameDidChangeNotification, object: scroll
            )
            // The reader's own hand, which is the one thing a bounds change cannot tell from this
            // app's own travel. See `TranscriptTable.onLiveScrollChange`.
            centre.addObserver(
                self, selector: #selector(liveScrollBegan),
                name: NSScrollView.willStartLiveScrollNotification, object: scroll
            )
            centre.addObserver(
                self, selector: #selector(liveScrolled),
                name: NSScrollView.didLiveScrollNotification, object: scroll
            )
            centre.addObserver(
                self, selector: #selector(liveScrollEnded),
                name: NSScrollView.didEndLiveScrollNotification, object: scroll
            )
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        // MARK: Entries

        func apply(
            entries newEntries: [TranscriptTableEntry],
            scale: CGFloat,
            environment: TranscriptRowEnvironment
        ) {
            // Held, so this pass waits. Only the last one is kept: each supersedes the one before
            // it, and applying six of them at the end would be six reloads of the same rows.
            guard !isHeld else {
                whileHeld = (newEntries, scale, environment)
                return
            }
            guard let tableView else { return }

            // **A new typeface or a new hover host is every cell.** Rare, because it takes a
            // settings change to move any of them, so a whole reload is the honest answer rather
            // than a diff of what each row happened to read.
            //
            // **The heights are a narrower question, and asking the wrong one was the whole of why
            // switching workspaces was slow.** `linkActions` carries the pane a link opens into, so
            // every workspace switch was an environment change, and every environment change
            // emptied the height cache: arriving at a conversation you had read a minute ago
            // rebuilt an `NSHostingView` for every row in the window. What a link does when it is
            // pressed cannot change how tall a paragraph is. See `wraps(differentlyFrom:)`.
            let previous = rowEnvironment
            rowEnvironment = environment
            let environmentMoved = previous != nil && previous != environment
            // The reload below is what says every cell holds values from the environment it was
            // built in, and a cell that recycles on its content key alone would take none of it.
            // See `cellGeneration`.
            if environmentMoved { cellGeneration += 1 }
            let wrapsDifferently = previous?.wraps(differentlyFrom: environment) ?? false
            if wrapsDifferently { heights.forget() }

            // The first width the table ever has, and any change of text size. Until a width
            // arrives every measurement is refused, and a table told a hair per row is a
            // transcript that is not there. See `TranscriptRowHeights.reset`.
            // The line height comes off the environment rather than beside `scale`, because it
            // arrives with everything else a row is drawn from and a second argument saying the
            // same thing is a second thing to forget to pass. See `TranscriptRowHeights.Measure`.
            let remeasured = heights.reset(
                width: columnWidth, scale: scale, leading: environment.lineHeight.ratio
            ) || wrapsDifferently

            let newIDs = newEntries.map(\.id)
            let change = TranscriptEntryChange.between(ids, newIDs)
            let changesFoldRows = pendingFoldRows && change.movesRows
            let foldAnchor = changesFoldRows ? pendingFoldAnchor : nil
            let fadesFoldRows = changesFoldRows
                && rowEnvironment?.reduceMotion != true
            if change.movesRows {
                pendingFoldRows = false
                pendingFoldAnchor = nil
            }

            // What has changed about the entries the two lists share, in the NEW list's indices,
            // and which of those are a fold the reader just clicked.
            //
            // Through the old list's own index rather than by arithmetic off the change's head
            // and tail runs. The arithmetic is shorter and it is exactly the kind of two lines
            // that is wrong for a month: an off-by-one here reloads a different row's cell than
            // the one whose content moved, which reads as a row that will not update rather than
            // as an index bug. One dictionary lookup per entry, on a pass that has just built one
            // closure per entry, is not the expensive thing here.
            var changed = IndexSet()
            var unfolding = IndexSet()
            func noteChange(old: Int, new: Int) {
                guard newEntries[new].contentKey != entries[old].contentKey else { return }
                changed.insert(new)
                if pendingUnfolds.contains(newEntries[new].id) { unfolding.insert(new) }
            }
            switch change {
            case .same:
                for offset in newEntries.indices { noteChange(old: offset, new: offset) }
            case .grew, .shrank:
                for offset in newEntries.indices {
                    guard let old = index[newEntries[offset].id] else { continue }
                    noteChange(old: old, new: offset)
                }
            case .rebuilt:
                // Every cell is going anyway.
                break
            }
            pendingUnfolds.removeAll()

            if change == .same, changed.isEmpty, !remeasured, !environmentMoved {
                // Nothing at all has moved. Not even a geometry report is owed.
                return
            }

            // Both read before anything moves under the reader. See `keepPlace`.
            // A disclosure click is navigation, even when the clicked row happens to be on the
            // last screen. Keep that row where it was instead of treating the new children as
            // live transcript activity and following them to the end.
            let wasAtEnd = changesFoldRows ? false : isFollowingAlong
            let anchor = foldAnchor ?? (change.movesRows ? anchorEntry() : nil)

            entries = newEntries
            ids = newIDs
            index = [:]
            for (offset, id) in newIDs.enumerated() { index[id] = offset }

            // **Rows in and out rather than `reloadData()`, and this is the whole of the scroll
            // stall.** See `TranscriptEntryChange`, which carries the measurement.
            //
            // **One edit, never two**, and `TranscriptTableUpdate` carries the three minute beach
            // ball that came of making both. A moved environment used to stage the rows out AND
            // then reload on top of them, so the reload had every staged row view to tear off the
            // window as well as the ones on screen, at O(n²) in the observers each one removes.
            let plan = TranscriptTableUpdate.plan(change: change, environmentMoved: environmentMoved)
            switch plan {
            case .nothing:
                break
            case .rows(let rowChange):
                switch rowChange {
                case .grew(let head, let tail):
                    rowsArrived(head: head, tail: tail, fading: fadesFoldRows, in: tableView)
                case .shrank(let head, let tail):
                    rowsLeft(head: head, tail: tail, fading: fadesFoldRows, in: tableView)
                case .same, .rebuilt:
                    // Neither reaches here: `plan` answers `.nothing` and `.reload` for them.
                    break
                }
            case .reload:
                // Every cell thrown away and the visible ones built again. A session being
                // replaced, and the environment the cells were built in having moved, and nothing
                // else should ever reach here.
                tableView.reloadData()
            }

            if remeasured {
                // **The screen first, exactly.** A reset empties the cache under cells that are
                // already drawn, and a cell holding the content it already holds never reports its
                // height again, so those rows would be answered from the mean for ever. One screen,
                // and none at all on the first pass of a pane, which has nothing laid out yet.
                measureExactly(visibleRows)
                noteHeights(IndexSet(integersIn: entries.indices))
            } else if !changed.isEmpty {
                // The cells first, so that a row whose height is about to travel already holds
                // what it is travelling to show. See `noteHeights(_:over:)`.
                //
                // Not after a reload, which has just rebuilt every one of these cells. Rebuilding
                // them a second time in the same pass is the second half of the same mistake the
                // plan above exists to stop; the measuring below still has to happen either way.
                if plan != .reload {
                    tableView.reloadData(
                        forRowIndexes: changed, columnIndexes: IndexSet(integer: 0)
                    )
                }
                // **A key that has just moved is a key nothing has measured, and this pass is the
                // cheapest moment to take it.** It used to go straight to `noteHeights`, which
                // tells the table what the cache holds, and for a new key the cache holds nothing:
                // `assumed` answers the running mean and the row is drawn at it.
                //
                // Nothing put that right afterwards. `HostedRow` reports through
                // `onChange(of: proxy.size.height)`, so a row whose key moved without its height
                // moving never reports again; the cell is not rebuilt as a new identity, so the
                // `initial: true` that would have does not fire; the warming pass only walks rows
                // ABOVE the screen; and the screen census saw the cache and the table agreeing
                // about the mean. A fold's line is the case that shipped: its key carries the
                // count in its words, so it moves on every call that lands, and it is one line
                // tall in every one of those states.
                //
                // `measureExactly` skips any key the cache already knows, so the ordinary changed
                // row, one that has been in this state before, costs a dictionary lookup.
                measureExactly(changed)
                noteHeights(changed.subtracting(unfolding))
                noteHeights(unfolding, over: unfoldSeconds)
            }

            keepPlace(wasAtEnd: wasAtEnd, anchor: anchor)
            // Off this pass, because this one runs inside `updateNSView` and what it calls writes
            // SwiftUI state. Reporting from here is "Modifying state during view update".
            Task { @MainActor [weak self] in self?.reportGeometry() }
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

        /// A row that draws nothing still has to be a row, because the table counts them and
        /// `rect(ofRow:)` is how every scroll in this file names a place. A hundredth of a point
        /// is the smallest thing that is still positive: five of them is half a pixel, and one
        /// that later has something to draw is remeasured the moment its content key moves.
        private static let hair: CGFloat = 0.01

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            // An increment, on a path AppKit may call for every row of the table. See
            // `TranscriptHoldCensus.heightAsks`, which is here to find out whether it does.
            TranscriptHoldCensus.askedHeight()
            guard entries.indices.contains(row) else { return Self.hair }
            return max(Self.hair, height(of: entries[row]))
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        func tableView(
            _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
        ) -> NSView? {
            guard entries.indices.contains(row), let rowEnvironment else { return nil }
            let entry = entries[row]
            // **A row that turned out to draw nothing gets no view at all, and that is most of a
            // session.** Sixty per cent of a real conversation is stream events with no view in
            // them, and a table builds one for every row in the visible rect: an `NSHostingView`
            // with a SwiftUI graph of its own, a runloop observer of its own, and a place of its
            // own in the layout. A profile of an upward scroll put 22 per cent of the main thread
            // in `NSHostingView.beginTransaction` and the graph flush under it, none of which any
            // counter here could see, because the cost is per LIVE view per display cycle rather
            // than per view built.
            //
            // **Measured, never merely claimed, and that is the whole safety of it.** This asks
            // what the row TURNED OUT to be when it was drawn, so nothing is owed a correction and
            // there is nothing left to learn by drawing it again. A row that has only been
            // ESTIMATED at nought, by `TranscriptRowInk`, is still built and still reports, which
            // is what would catch that guess being wrong. And a row that gains content gets a new
            // content key, misses here, and is built like any other row: this cannot bring back
            // the blank between two Bash rows, because a row it silences has already told the
            // table it draws nothing.
            //
            // **A stored row and nothing else, and that is not a tidiness.** Three entries in this
            // list re-render from their own observation and change height without their content
            // key moving: the streaming tail, the setup log, and the delivery at the head of the
            // queue. The tail draws NOTHING between turns, so it would be measured at nought,
            // silenced, and then have no view at all on the frame a turn starts: the answer would
            // never appear. `noted` is what keeps those three right and it needs a cell to hear
            // from. A stored row cannot do that to us, because everything that changes what one
            // draws is in its key.
            if !entry.id.redrawsItself, heights.measuredNothing(entry.contentKey) { return nil }
            let identifier = NSUserInterfaceItemIdentifier("bloom.transcript.cell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self)
                as? TranscriptTableCell ?? TranscriptTableCell(identifier: identifier)
            cell.onHeightChange = { [weak self] id, key, height in
                self?.noted(height: height, of: key, for: id)
            }
            // **Every row in the visible rect gets one of these, and this is where a row's SwiftUI
            // graph is actually built.** It is outside the pane's own layout pass, so
            // `PaneLayoutTiming` never saw it: that reported a ceiling of 0.8ms while a quarter of
            // the frames were being dropped. Timed rather than assumed, and only the calls that
            // really replace the root view, because a recycled cell holding what it already holds
            // returns early. See `TranscriptHoldCensus.cellSeconds`.
            let started = TranscriptHoldCensus.clock()
            let rebuilt = cell.apply(
                entry: entry, environment: rowEnvironment, generation: cellGeneration
            )
            TranscriptHoldCensus.askedCell(
                rebuilt: rebuilt, seconds: TranscriptHoldCensus.since(started)
            )
            return cell
        }

        // MARK: Heights

        /// What the table is told a row is, which is never a measurement.
        ///
        /// **This used to measure on a miss, and that was the whole of "opening a workspace or a
        /// tab with a chat in it is slow".** A table asks for every row it holds, so a pane
        /// arriving at a conversation built an `NSHostingView` for each of the four hundred rows
        /// in its window, none of which anybody saw. Now an unmeasured row is answered with
        /// `TranscriptRowHeights.assumed` and put right when it is drawn, or when a placement is
        /// about to show it: see `measureLanding`.
        ///
        /// The three entries that re-render themselves are answered the same way. What keeps them
        /// right is `noted` below, which is authoritative and which the tail triggers itself as it
        /// grows.
        ///
        /// ## AppKit estimates too, and leaving it to is the faster of the two
        ///
        /// macOS 13 gave `NSTableView` its own row height estimation: it asks for a fraction of
        /// the heights and guesses the rest, replacing them as rows come into view. So there are
        /// two estimating machines here, one under the other, and the obvious suspicion is that
        /// they fight. **Measured, and they do not.** With
        /// `-NSTableViewCanEstimateRowHeights NO`, on the same binary and the same machine state,
        /// the delegate was asked for 2,523 heights rather than 1,752 and the share of dropped
        /// frames got WORSE, 28.9 per cent to 32.6. AppKit's estimation is doing us a favour.
        ///
        /// Written down because it is a thing somebody will otherwise turn off again in six
        /// months on the strength of how plausible it sounds.
        private func height(of entry: TranscriptTableEntry) -> CGFloat {
            guard heights.isReady else { return Self.hair }
            return CGFloat(heights.assumed(
                for: entry.contentKey, shape: entry.shape, drawsNothing: entry.drawsNothing
            ))
        }

        /// The one thing a row is hosted in to be measured, kept rather than built per row. See
        /// `measure(_:at:)`, which carries why keeping it is safe now and was not before. Lazy, so
        /// a coordinator that never measures never builds one.
        private lazy var sizer = NSHostingController(rootView: AnyView(EmptyView()))

        /// **What this row comes to at this width, asked of a hosting controller.**
        ///
        /// It was a fresh `NSHostingView` per row, with a required width constraint,
        /// `layoutSubtreeIfNeeded()` and `fittingSize`. The comment beside it said a reused
        /// hosting view "does not reliably forget the row before", and that is a description of
        /// `fittingSize` rather than of reuse: `fittingSize` is the Auto Layout engine's answer for
        /// the view as it stands, so a reused view hands back whatever the last solve left in it.
        /// `sizeThatFits(in:)` takes a PROPOSAL and answers for the content it has been handed, so
        /// there is nothing left over to forget and the controller can be kept. It is also the
        /// supported width-constrained measurement, where `fittingSize` under a constraint is a
        /// solver result that happens to agree.
        ///
        /// Timed on this Mac against the owner's session: 0.270ms a row for the fresh view, 0.103ms
        /// for this. Nothing else about the measurement moves. `HostedRow` is untouched, because
        /// the measuring copy and the drawing copy passing through identical modifiers is the whole
        /// reason that type exists; `.id` is added here, which the drawing copy already had, so the
        /// two are now closer rather than further apart, and it is what tells SwiftUI that the next
        /// row is a different view rather than this one changing.
        ///
        /// The width is still `columnWidth`, carried in through `TranscriptRowHeights.measure`,
        /// which is the TABLE's width and not the clip view's. See `columnWidth`, which carries
        /// what measuring against the wrong one clipped.
        private func measure(_ entry: TranscriptTableEntry, at width: CGFloat) -> CGFloat {
            guard let rowEnvironment else { return 0 }
            // The one place a row is hosted to measure it, so the one place worth counting. See
            // `TranscriptHoldCensus`.
            TranscriptHoldCensus.measured()
            sizer.rootView = AnyView(
                HostedRow(content: entry.content(), report: { _ in }, fills: false)
                    .id(entry.id)
                    .transcriptRowEnvironment(rowEnvironment)
            )
            // Unconstrained downwards, which is what `fills: false` is for: the measuring copy
            // takes its own ideal height rather than filling a row it has not been given.
            let height = sizer.sizeThatFits(
                in: CGSize(width: width, height: .greatestFiniteMagnitude)
            ).height
            // Nought is a real answer, and `TranscriptRowHeights` carries what pretending
            // otherwise cost.
            return height
        }

        /// **What the row turned out to be when it was drawn, which outranks anything measured off
        /// screen.** See `TranscriptRowHeights.note`.
        ///
        /// **A report carries the content it was measured for, and it used to carry only the id.**
        /// An entry id is an ordinal within one conversation, so `.row(37)` in the workspace being
        /// left and `.row(37)` in the one arriving are the same value, and a report landing after
        /// the switch was filed under whatever the ARRIVING row's key is. Nothing would ever take
        /// that number again: `measureExactly` skips a key the cache knows, the screen census sees
        /// the table and the cache agreeing, and the repair confirms it rather than measuring. The
        /// row is then drawn at another conversation's height until its key moves.
        ///
        /// Reasoned from the id rather than photographed, unlike the estimate this shipped beside.
        /// The guard costs one comparison and closes the class: a height is about the content it
        /// was taken from, so a report whose content has been replaced is not evidence about what
        /// is there now.
        private func noted(
            height: CGFloat, of contentKey: TranscriptContentKey, for entryID: TranscriptEntryID
        ) {
            // The tail goes on growing inside its frozen cell while a pane is dragged, and a
            // height taken from it would be filed against the entry list this pass is not
            // applying. It is remeasured when the hold lets go, with everything on screen.
            guard !isHeld else { return }
            guard let row = index[entryID], entries.indices.contains(row),
                  entries[row].contentKey == contentKey else { return }
            // The other half of the same question `measureExactly` asks: a row the reader was
            // being shown, reporting that it drew nothing after all. See
            // `TranscriptHoldCensus.silenced`.
            if height == 0, !entries[row].drawsNothing {
                noteSilence(row: row, entry: entries[row], source: "drawn")
            }
            guard heights.note(height, for: contentKey, shape: entries[row].shape) else { return }
            // **News to the cache is not always news to the table.** A row the table is already
            // drawing at this height needs no `noteHeightOfRows`, and the whole of a correction's
            // cost is that call: it moves the document's total and makes AppKit lay out every row
            // below the one that changed, which near the top of a long conversation is all of
            // them. Measured on a 2,981 row session, an upward sweep made 285 of those calls and
            // resized the document on 214 frames of 312. Most of them were rows that draw nothing
            // arriving at the nought they were already being drawn at.
            let told = tableView?.rect(ofRow: row).height
            let drawn = max(Double(Self.hair), TranscriptRowHeights.rounded(Double(height)))
            if let told, TranscriptRowHeights.isSameHeight(Double(told), drawn) { return }
            owedHeights.insert(entryID)
            drainOwedHeights()
        }

        /// **Tells the table every correction the cache has taken and it has not been told about.**
        ///
        /// Its own method because a report is no longer the only thing that can owe one. A hold
        /// takes the queue out of flight, and if the hold turns out not to have changed the width
        /// then everything in it is still true and has to be said. See `holdEnded`.
        private func drainOwedHeights() {
            // A height correction moves the table's document and restoring the visible anchor
            // moves the clip view. Both are correct while the view is still, but either one fights
            // AppKit's own offset while a trackpad gesture or its momentum is in flight. Keep
            // taking the measurements into the cache, then tell the table once the reader lets go.
            guard owedWork == nil, !owedHeights.isEmpty, !isLiveScrolling else { return }
            owedWork = Task { @MainActor [weak self] in
                guard let self else { return }
                owedWork = nil
                // The task begins on a later main-actor turn. A gesture can start between being
                // scheduled and arriving here, so check again before taking the queue out.
                guard !isLiveScrolling else { return }
                let owed = owedHeights
                owedHeights = []
                // **Where each of them is NOW.** An id that has left the list is dropped, which is
                // what a rebuilt list comes to. See `owedHeights`.
                let rows = IndexSet(owed.compactMap(rowOf))
                guard !rows.isEmpty else { return }
                let wasAtEnd = isFollowingAlong
                // **The row being corrected is usually above the reader.** Scrolling up brings
                // rows in at the top, each reports a height that differs from what it was measured
                // at, and every correction moves everything below it. Without the anchor the text
                // slides under the eye on the way up.
                let anchor = anchorEntry()
                noteHeights(rows)
                // **The correction is also what leaves a reader short of the end**, and it is the
                // second half of "the pill does not go all the way down": a scroll that was right
                // when it was issued is short the moment a row below the fold turns out taller
                // than it was measured at.
                keepPlace(wasAtEnd: wasAtEnd, anchor: anchor)
                reportGeometry()
                // A turn later, because a table lays a height change out on the pass after it is
                // told about it.
                await Task.yield()
                checkCorrected(owed)
            }
        }

        /// Where an entry is in the list now, or nothing if it has left it.
        private func rowOf(_ entryID: TranscriptEntryID) -> Int? {
            guard let row = index[entryID], entries.indices.contains(row) else { return nil }
            return row
        }

        /// **A row is the height it draws at, and this is the thing that says so.**
        ///
        /// Nothing compared a row's estimate against the height it turned out to be, so a
        /// correction that was filed against the wrong row shipped and was found by eye: a screen
        /// of one line Bash rows with a hundred points of blank under each. A row that has
        /// reported its drawn height and been corrected must be a row the table now draws at that
        /// height, and a count of the ones that are not is the number to watch.
        private func checkCorrected(_ owed: Set<TranscriptEntryID>) {
            guard let tableView, !isHeld else { return }
            var wrong = 0
            // A row that has reported again since is owed another correction rather than missing
            // this one, which is the streaming tail on every frame of a turn.
            for id in owed where !owedHeights.contains(id) {
                guard let row = rowOf(id),
                      heights.height(for: entries[row].contentKey) != nil else { continue }
                let told = tableView.rect(ofRow: row).height
                let drawn = owedHeight(of: entries[row])
                guard !TranscriptRowHeights.isSameHeight(Double(told), drawn) else { continue }
                wrong += 1
                #if DEBUG
                // Said rather than trapped. A false positive is a row mid animation, and stopping
                // the owner's build over one would be worse than the gap this is looking for.
                FileHandle.standardError.write(Data(
                    "transcript: row \(row) drew at \(drawn), the table says \(told)\n".utf8
                ))
                #endif
            }
            TranscriptHoldCensus.corrected(rows: owed.count, uncorrected: wrong)
        }

        /// **What the reader can see, and how much of it is a guess.**
        ///
        /// `checkCorrected` can only speak for rows that reported. A row that never reports at all
        /// is answered from the mean for ever and nothing above would say so, which is the shape
        /// of blank this file has now been wrong about twice. This counts the visible rows the
        /// table is drawing at a height nobody has measured.
        ///
        /// **On the settle, and it used to be on every movement of the clip view.** A screenful is
        /// not a fixed number of rows: most of a session draws nothing and is a hundredth of a
        /// point tall, so a viewport can span hundreds of rows rather than the thirty this walked
        /// when it was written. Instrumentation that grows with what it is watching distorts what
        /// it measures, and the three numbers anybody reads from it are settled ones anyway.
        private func censusOfTheScreen(settled: Bool = false) {
            guard let tableView, heights.isReady else { return }
            var estimated = 0
            var wrong = 0
            for row in visibleRows where entries.indices.contains(row) {
                if isGuessed(entries[row]) { estimated += 1 }
                let told = Double(tableView.rect(ofRow: row).height)
                if !TranscriptRowHeights.isSameHeight(told, owedHeight(of: entries[row])) {
                    wrong += 1
                }
            }
            TranscriptHoldCensus.sawScreen(estimated: estimated, wrong: wrong, settled: settled)
            // **What this counts, it now also puts right.** A row the table draws at a height
            // nobody measured it at is the bug with two faces: a row over the row beneath it, or a
            // last line under the composer that the scroller will not reach. `drainOwedHeights`
            // closes the one path that was losing corrections, and this closes the class: whatever
            // else could ever leave the table disagreeing with the cache, one screenful of rows is
            // reconciled the moment the reader stops moving.
            //
            // On the settle only. It writes heights, which moves the document, and doing that on a
            // frame somebody is scrolling is the stutter rather than the cure.
            if settled, TranscriptRowHeights.needsRepair(guessed: estimated, wrong: wrong) {
                repairTheScreen()
            }
            #if DEBUG
            // Which rows, once the screen has stopped moving, because a guess that is standing
            // there is worth naming and a guess mid flick is not.
            if settled, estimated > 0 {
                let named = visibleRows
                    .filter { entries.indices.contains($0) && isGuessed(entries[$0]) }
                    .map { entries[$0].id.description }
                FileHandle.standardError.write(Data(
                    "transcript: \(estimated) guessed rows on screen: \(named)\n".utf8
                ))
            }
            #endif
        }

        /// **Tells the table what the cache holds for every row on screen.**
        ///
        /// The safety net under `drainOwedHeights`, and deliberately blunt: it does not care how
        /// the table came to disagree, only that a reader is looking at rows drawn at heights
        /// nobody measured them at. One screenful, once, when nothing is moving.
        private func repairTheScreen() {
            let rows = IndexSet(visibleRows.filter { entries.indices.contains($0) })
            guard !rows.isEmpty else { return }
            let wasAtEnd = isFollowingAlong
            let anchor = anchorEntry()
            // **Measured before it is told, because re-telling a guess tells the table the guess
            // again.** This used to hand the table whatever `assumed` said, which for a row nobody
            // has measured is the running mean, so a screenful of guesses was reported by the
            // census and then confirmed by the repair. `measureExactly` skips every key the cache
            // knows, so on a screen that is already right this costs one lookup a row.
            measureExactly(rows)
            noteHeights(rows)
            keepPlace(wasAtEnd: wasAtEnd, anchor: anchor)
            reportGeometry()
        }

        /// Whether this row is on screen at a number somebody guessed.
        ///
        /// **A row claimed to draw nothing is answered rather than guessed**, so it is not counted
        /// here: `TranscriptRowInk` decided it from the row itself, and nought is the whole of what
        /// such a row can be. Counting those would have this report a screenful of alarms for the
        /// change that removed the alarms.
        private func isGuessed(_ entry: TranscriptTableEntry) -> Bool {
            heights.height(for: entry.contentKey) == nil && !entry.drawsNothing
        }

        /// The height this row ought to be drawn at: what was measured, what it is claimed to be,
        /// or the mean. The same number `height(of:)` gives the table, so the two cannot disagree
        /// about what counts as a row drawn wrong.
        private func owedHeight(of entry: TranscriptTableEntry) -> Double {
            max(
                Double(Self.hair),
                heights.assumed(
                    for: entry.contentKey, shape: entry.shape, drawsNothing: entry.drawsNothing
                )
            )
        }

        /// Every height change in this file goes through here.
        ///
        /// **`noteHeightOfRows(withIndexesChanged:)` animates, and almost never should.** It is
        /// the AppKit half of "the animations get in the way": a row correcting its height slides
        /// the whole document under the reader over a quarter of a second, and a transcript
        /// correcting several does it several times over. There is nothing to watch in a
        /// measurement being put right, so the default here is no duration at all.
        ///
        /// The exception is a fold the reader has just clicked open, which is the one height
        /// change in this file that somebody asked for. See `unfoldSeconds`.
        private func noteHeights(_ rows: IndexSet, over seconds: Double = 0) {
            guard let tableView, !rows.isEmpty else { return }
            if seconds > 0 {
                // Only while the row travels, and only the rows travelling. A cell is exactly its
                // row, and its content is already at the height it is growing towards, so without
                // this the unfolded detail is drawn over the rows below for the length of the
                // animation. With it, the detail is revealed as the row opens. It cannot be left
                // on: `ArrivingRow` settles a row in by drawing it a few points low, and a clipped
                // cell would cut the bottom of that off.
                for row in rows {
                    let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                    (cell as? TranscriptTableCell)?.clips(whileGrowingFor: seconds)
                }
            }
            let started = TranscriptHoldCensus.clock()
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = seconds
            if seconds > 0 {
                NSAnimationContext.current.timingFunction =
                    CAMediaTimingFunction(name: .easeOut)
            }
            // What AppKit does here is the other unmeasured half: a height changing near the top
            // of a long list moves every row below it. See `TranscriptHoldCensus.noteSeconds`.
            tableView.noteHeightOfRows(withIndexesChanged: rows)
            NSAnimationContext.endGrouping()
            TranscriptHoldCensus.noted(
                rows: rows.count, seconds: TranscriptHoldCensus.since(started)
            )
        }

        /// A fold is about to open or close, so the height change it causes is the one this file
        /// may animate.
        ///
        /// **The height a fold changes is the TABLE's, not the row's.** The row is remeasured
        /// and the table is told a number, and a number arriving is not a transition, so the
        /// travel is the table's row-height animation rather than a `withAnimation` inside the row.
        ///
        /// A set rather than a flag, because unfolding one row and folding another in the same
        /// pass is a thing a keyboard can do, and because a fold that is somehow not applied on
        /// the next pass has to expire rather than animate whatever height change comes next.
        func willUnfold(_ entryID: TranscriptEntryID) {
            pendingUnfolds.insert(entryID)
        }

        func willChangeFoldRows(_ entryID: TranscriptEntryID) {
            pendingFoldRows = true
            pendingFoldAnchor = anchorEntry(entryID)
            aimingElsewhere()
        }

        /// How long a fold takes, or nothing at all under Reduce Motion. Read from the row
        /// environment rather than from the setting, so the table and the rows inside it cannot
        /// disagree about whether this reader wants movement.
        private var unfoldSeconds: Double {
            guard let rowEnvironment else { return 0 }
            return TranscriptMotion.disclosure(reduceMotion: rowEnvironment.reduceMotion) ?? 0
        }

        // MARK: Keeping the reader's place

        /// **Where the reader goes after something under them has moved.** One answer, because
        /// there were three of these and the resize one silently left `wasAtEnd` out: a reader
        /// sitting at the live end without having asked for it was anchored to their top row by a
        /// divider drag, while the comment beside it argued that a resize moves the end as much as
        /// it moves anything. It does, so it gets the same answer as a row landing.
        ///
        /// The rule is `TranscriptAnchor.place`, in the core, because it had drifted once already
        /// and a decision taken in a view is a decision nothing can test. `wasAtEnd` is read
        /// before the move rather than here. Anything that is not the end keeps the ROW that was
        /// at the top of the pane, which is the thing a point offset cannot do and the whole
        /// reason for the table.
        private func keepPlace(
            wasAtEnd: Bool, anchor: (id: TranscriptEntryID, delta: CGFloat)?
        ) {
            switch TranscriptAnchor.place(
                holdsEnd: holdsEnd,
                wasAtEnd: wasAtEnd,
                followerDriving: isFollowerDriving,
                hasAnchor: anchor != nil
            ) {
            case .end:
                putEnd()
            case .anchor:
                if let anchor { restore(anchor) }
            case .stay:
                break
            }
        }

        /// Whether the reader is still following along, which is `ScrollEnd`'s question with a
        /// line or two of slack, and not `TranscriptTableGeometry.isAtEnd`'s exact one.
        private var isFollowingAlong: Bool {
            let geometry = currentGeometry
            return ScrollEnd.isAtEnd(
                contentHeight: geometry.contentHeight,
                viewportHeight: geometry.viewportHeight,
                offset: geometry.offset
            )
        }

        // MARK: Scrolling

        var currentGeometry: TranscriptTableGeometry {
            guard let scrollView, let document = scrollView.documentView else {
                return TranscriptTableGeometry()
            }
            let clip = scrollView.contentView
            return TranscriptTableGeometry(
                offset: clip.bounds.origin.y,
                // `frame` rather than `bounds`, so this agrees with `NSScrollView.endOffset`,
                // which carries why.
                contentHeight: document.frame.height,
                viewportHeight: clip.bounds.height,
                viewportWidth: clip.bounds.width
            )
        }

        var topmostEntry: TranscriptEntryID? {
            guard let tableView, let scrollView else { return nil }
            let visible = scrollView.contentView.documentVisibleRect
            let range = tableView.rows(in: visible)
            guard range.length > 0, entries.indices.contains(range.location) else { return nil }
            return entries[range.location].id
        }

        /// The row at the top of the pane and how far above its own top the pane starts, which is
        /// the pair `TranscriptAnchor` restores a reader from.
        ///
        /// **A chain rather than the topmost entry alone, because four of the entries in this list
        /// are not stored rows and have no sequence number at all.** A reader anywhere near the
        /// live end has the streaming tail, the bubble being sent or a queued message at the top of
        /// the pane, and `topmostEntry` named one of those: `seq` was nil, the pane wrote down no
        /// anchor, and it fell back to a point measured against a content height that is a fact
        /// about what has been measured rather than about the conversation. That is where the nil
        /// anchors came from.
        ///
        /// Upwards first, to the last stored row above the fold, because that is what the delta is
        /// for: it is normally negative anyway, and the row starting above the viewport restores
        /// the same place exactly. Downwards only when there is nothing above, which is a reader at
        /// the very top of a conversation with the setup log over it.
        var topmostPlace: (seq: Int, delta: CGFloat)? {
            guard let tableView, let scrollView else { return nil }
            let visible = scrollView.contentView.documentVisibleRect
            let range = tableView.rows(in: visible)
            guard range.length > 0 else { return nil }
            func place(_ row: Int) -> (seq: Int, delta: CGFloat)? {
                guard entries.indices.contains(row), let seq = entries[row].id.seq else { return nil }
                return (seq, CGFloat(TranscriptAnchor.delta(
                    rowTop: tableView.rect(ofRow: row).minY, viewportTop: visible.minY
                )))
            }
            for row in stride(from: range.location, through: 0, by: -1) {
                if let found = place(row) { return found }
            }
            for row in stride(from: range.location + 1, to: entries.count, by: 1) {
                if let found = place(row) { return found }
            }
            return nil
        }

        func isAboveViewport(_ entryID: TranscriptEntryID) -> Bool? {
            guard let tableView, let scrollView, let row = index[entryID] else { return nil }
            return tableView.rect(ofRow: row).maxY <= scrollView.contentView.bounds.minY
        }

        // MARK: The end, and holding it

        func goToEnd() {
            // Nothing pins the view while the reader has hold of it. The follower asks for its
            // hold back the moment it is paused, which is the moment the reader grabbed the view,
            // and obeying that would be this file yanking somebody down as they scroll away.
            guard !isLiveScrolling else { return }
            putEnd()
            // **A movement rather than an instruction while the follower is running**, because
            // keeping the view at the end during a turn is precisely the follower's job and it is
            // the only one of the two that can make the last of that travel something the eye can
            // read. It hands back through `onStop`, and whoever asked to be at the end gets the
            // standing instruction then.
            guard !isFollowerDriving else { return }
            holdsEnd = true
            // **And once more on the next turn**, because the content this one is aimed at may
            // not have been laid out yet: a window just moved to the tail, a bubble drawn on the
            // frame Return was pressed, a row inserted in the same update. Each changes where the
            // end is after the line above has read it.
            endWork?.cancel()
            endWork = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self, holdsEnd else { return }
                putEnd()
            }
        }

        func releaseEnd() {
            holdsEnd = false
            isSettlingResizeAtEnd = false
            endWork?.cancel()
            endWork = nil
        }

        func followerTookOver() -> Bool {
            // Read before releasing the standing instruction. A response can add more than the
            // near-end threshold in one pass, but a view the table was holding at the end still
            // belongs to the follower rather than to a reader who moved away.
            let ownedEnd = holdsEnd || isFollowingAlong
            isFollowerDriving = true
            releaseEnd()
            return ownedEnd
        }

        func followerHandedBack() {
            isFollowerDriving = false
        }

        private func putEnd() {
            guard let scrollView else { return }
            // The last screen, measured before the end is claimed to be anywhere. Read again
            // afterwards, because measuring it is what moves the end: an estimate for a row nobody
            // has drawn is what the sum said, and the sum is where the scroller stops.
            //
            // **This is the reachable end.** Reported as "when I'm at the bottom of a chat and it
            // gets resized, sometimes I get placed a little higher and can't reach the bottom
            // anymore": the rows at the end were short by whatever the estimate was out by, so the
            // document ended above the content and the scroller could not travel to it.
            //
            // Twice at most, because measuring the last screen is what moves the end and the
            // screen at the moved end can hold a row the first pass did not reach. The second
            // round costs nothing once the rows are measured, which is every return to a
            // conversation this pane has already drawn.
            for _ in 0..<2 { measureLanding(at: scrollView.endOffset) }
            // The only number that means the end. A row being *visible* is not it: the last row of
            // a transcript is often taller than the pane. See `NSScrollView.endOffset`.
            put(scrollView.endOffset, in: scrollView)
        }

        func scroll(to entryID: TranscriptEntryID, anchor: UnitPoint) {
            // Somewhere that is not the end, so whatever asked to be at the end has been overruled.
            aimingElsewhere()
            put(at: entryID, anchor: anchor)
            // **And once more on the next turn, for the same reason `goToEnd` says it twice.** A
            // row is scrolled to at the height the table currently believes it is. Unfolding 1,381
            // lines of setup log and asking for the end of it lands at the height the folded row
            // was measured at, thousands of points short; the correction arrives one turn later.
            reaimWork?.cancel()
            reaimWork = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self else { return }
                reaimWork = nil
                put(at: entryID, anchor: anchor)
            }
        }

        private func put(at entryID: TranscriptEntryID, anchor: UnitPoint) {
            guard let tableView, let scrollView, let row = index[entryID] else { return }
            func target() -> CGFloat {
                let rect = tableView.rect(ofRow: row)
                return TranscriptAnchor.offset(
                    rowTop: rect.minY,
                    rowHeight: rect.height,
                    viewportHeight: scrollView.contentView.bounds.height,
                    anchor: anchor.y
                )
            }
            // Aimed at where the estimates say the row is, measured there, and then aimed again at
            // where it turned out to be: measuring the screen is what moves it.
            measureLanding(at: target())
            put(target(), in: scrollView)
        }

        /// The same as above, aimed by a delta rather than by a `UnitPoint`, and it says itself
        /// twice for the same reason.
        func scroll(to entryID: TranscriptEntryID, delta: CGFloat) {
            aimingElsewhere()
            put(at: entryID, delta: delta)
            reaimWork?.cancel()
            reaimWork = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self else { return }
                reaimWork = nil
                put(at: entryID, delta: delta)
            }
        }

        private func put(at entryID: TranscriptEntryID, delta: CGFloat) {
            guard let tableView, let scrollView, let row = index[entryID] else { return }
            func target() -> CGFloat {
                CGFloat(TranscriptAnchor.offset(
                    rowTop: tableView.rect(ofRow: row).minY, delta: delta
                ))
            }
            measureLanding(at: target())
            put(target(), in: scrollView)
        }

        func scroll(toY y: CGFloat) {
            aimingElsewhere()
            guard let scrollView else { return }
            measureLanding(at: y)
            put(y, in: scrollView)
        }

        /// Somebody is taking the view somewhere that is not the end, so every standing claim on
        /// it comes down first.
        private func aimingElsewhere() {
            isFollowerDriving = false
            releaseEnd()
        }

        private func put(_ y: CGFloat, in scrollView: NSScrollView) {
            let clip = scrollView.contentView
            // **Nothing at all is decided from a pane nobody has laid out**, and this is the
            // blank transcript a composer divider left behind. The end of the content resolved
            // against a viewport of no height is the whole content height, which is the point
            // BELOW the last row, and the clamp below happily allows it: a reader sitting at the
            // live end while the composer takes the pane's height for a pass is put there and
            // cannot be brought back, because every recovery in this file needs a row on screen
            // to start from. `measureLanding` refuses the same pane a few lines down. See
            // `TranscriptAnchor.canPlace`, which is that rule where it can be tested.
            guard TranscriptAnchor.canPlace(viewportHeight: Double(clip.bounds.height)) else {
                return
            }
            let target = TranscriptAnchor.clamped(
                y,
                contentHeight: Double(scrollView.documentView?.frame.height ?? 0),
                viewportHeight: clip.bounds.height
            )
            // Its own tolerance, and a small one on purpose: this asks whether the write would
            // move anything at all, not whether the view is at the end. A point of slack here,
            // which is what `TranscriptAnchor.isAtEnd` allows for a clip view's rounding, would
            // refuse a real correction.
            guard abs(clip.bounds.origin.y - target) > 0.01 else { return }
            TranscriptHoldCensus.placed()
            // So that the escape in `clipMoved` does not read this file's own arrival at the end
            // as the reader scrolling away from it.
            isPutting = true
            clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: target))
            scrollView.reflectScrolledClipView(clip)
            isPutting = false
        }

        /// The two ways the table is told rows moved, each with a name of its own **so that the
        /// next `sample` can tell them apart** and from the third way, which is `reloadData` at
        /// the call site above. An earlier profile put `apply` at 47.7 per cent of the main thread
        /// with `NSHostingView` under it and `measure` at half a per cent, which only means a
        /// reload rebuilding cells if the plan really was `.reload`.
        private func rowsArrived(
            head: Range<Int>, tail: Range<Int>, fading: Bool, in tableView: NSTableView
        ) {
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = fading ? Motion.hoverSeconds : 0
            tableView.beginUpdates()
            // The head first, so that the indices the tail is named by are the indices the table
            // has by the time it hears about them. Both are indices into the NEW list, which is
            // what `TranscriptEntryChange` promises and what its own test checks by rebuilding the
            // list from them.
            let animation: NSTableView.AnimationOptions = fading ? .effectFade : []
            if !head.isEmpty { tableView.insertRows(at: IndexSet(integersIn: head), withAnimation: animation) }
            if !tail.isEmpty { tableView.insertRows(at: IndexSet(integersIn: tail), withAnimation: animation) }
            tableView.endUpdates()
            NSAnimationContext.endGrouping()
        }

        private func rowsLeft(
            head: Range<Int>, tail: Range<Int>, fading: Bool, in tableView: NSTableView
        ) {
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = fading ? Motion.hoverSeconds : 0
            tableView.beginUpdates()
            // And the tail first here, for the same reason turned around: both are indices into
            // the OLD list, so the later run has to go before the earlier one moves it.
            let animation: NSTableView.AnimationOptions = fading ? .effectFade : []
            if !tail.isEmpty { tableView.removeRows(at: IndexSet(integersIn: tail), withAnimation: animation) }
            if !head.isEmpty { tableView.removeRows(at: IndexSet(integersIn: head), withAnimation: animation) }
            tableView.endUpdates()
            NSAnimationContext.endGrouping()
        }

        /// The row at the top of the pane and how far above it the viewport starts, so a growth
        /// that adds rows above the reader can put them back on the same ROW rather than at the
        /// same point. See `TranscriptAnchor`.
        private func anchorEntry() -> (id: TranscriptEntryID, delta: CGFloat)? {
            guard let tableView, let scrollView, let id = topmostEntry,
                  let row = index[id] else { return nil }
            let visible = scrollView.contentView.documentVisibleRect
            return (
                id,
                CGFloat(TranscriptAnchor.delta(
                    rowTop: tableView.rect(ofRow: row).minY, viewportTop: visible.minY
                ))
            )
        }

        /// The clicked disclosure row at its current visual position. Unlike `anchorEntry()`,
        /// this keeps the control itself under the pointer while rows open or close beneath it.
        private func anchorEntry(
            _ entryID: TranscriptEntryID
        ) -> (id: TranscriptEntryID, delta: CGFloat)? {
            guard let tableView, let scrollView, let row = index[entryID] else { return nil }
            return (
                entryID,
                CGFloat(TranscriptAnchor.delta(
                    rowTop: tableView.rect(ofRow: row).minY,
                    viewportTop: scrollView.contentView.bounds.origin.y
                ))
            )
        }

        private func restore(_ anchor: (id: TranscriptEntryID, delta: CGFloat)) {
            guard let tableView, let scrollView, let row = index[anchor.id] else { return }
            put(
                TranscriptAnchor.offset(
                    rowTop: tableView.rect(ofRow: row).minY, delta: anchor.delta
                ),
                in: scrollView
            )
        }

        // MARK: What the scroll view says

        @objc private func clipMoved() {
            // **However the view got away from the end, the standing instruction goes with it.**
            //
            // `willStartLiveScroll` below is the ordinary way a reader takes hold, and it covers a
            // trackpad, a wheel with gesture phases and a drag of the scroller. A legacy mouse
            // that emits no phase at all posts no live scroll notifications, and a reader on one
            // must still be able to scroll up and stay there. So the position itself is the last
            // word: if the view is no longer at the end and this file did not put it there, then
            // nobody is holding it any more.
            if holdsEnd, !isPutting, !isSettlingResizeAtEnd, !currentGeometry.isAtEnd {
                releaseEnd()
            }
            // The reader is moving, so whatever was being prepared for them is now on their frame.
            // Started again by the settle when they stop. See `warmAhead`.
            warmWork?.cancel()
            warmWork = nil
            reportGeometry()
            scheduleSettle()
        }

        @objc private func liveScrollBegan() {
            guard !isLiveScrolling else { return }
            isLiveScrolling = true
            // The reader outranks every standing claim on this view, including one made by a
            // follower that is about to be paused for exactly this reason.
            aimingElsewhere()
            reaimWork?.cancel()
            onLiveScrollChange?(true)
        }

        /// Belt to the braces above. AppKit posts this for every step of a user-initiated scroll,
        /// and a gesture that somehow began without a `willStartLiveScroll` still has to take the
        /// hold down on the frame it reaches here.
        ///
        /// **And a gesture that begins here can end without anything saying so, which used to
        /// latch the hold on for good.** `isLiveScrolling` refuses `goToEnd` and pauses the
        /// follower, so a step arriving after its own gesture's `didEndLiveScroll` turned both
        /// mechanisms off and nothing turned them back on until the next cleanly completed
        /// gesture. That is the "sometimes it just stops following" shape, and it survives a whole
        /// session because nothing else clears the flag: the settle that would notice is itself
        /// gated on it.
        ///
        /// So the belt watches for quiet, and only when it is the belt that started the gesture. A
        /// step inside an ordinary one does no more than stamp the clock.
        @objc private func liveScrolled() {
            lastLiveScroll = CACurrentMediaTime()
            guard !isLiveScrolling else { return }
            liveScrollBegan()
            watchForQuiet()
        }

        /// How long without a step of a gesture nothing announced counts as that gesture being
        /// over. Comfortably longer than a frame at any rate this app runs at, and shorter than
        /// the settle, so a hold that was never taken down is gone before the place is written.
        private static let quietSeconds: Double = 0.2

        private func watchForQuiet() {
            quietWork?.cancel()
            quietWork = Task { @MainActor [weak self] in
                while true {
                    try? await Task.sleep(for: .seconds(Self.quietSeconds))
                    guard !Task.isCancelled, let self, isLiveScrolling else { return }
                    guard CACurrentMediaTime() - lastLiveScroll >= Self.quietSeconds else { continue }
                    // Cleared before the call rather than after, so the cancellation inside it is
                    // not this task cancelling itself.
                    quietWork = nil
                    return liveScrollEnded()
                }
            }
        }

        @objc private func liveScrollEnded() {
            quietWork?.cancel()
            quietWork = nil
            guard isLiveScrolling else { return }
            isLiveScrolling = false
            onLiveScrollChange?(false)
            // Rows first seen during the gesture have reported their exact heights, but applying
            // those reports was held so the content could not be pushed against the reader's
            // movement. Apply them now as one anchored correction.
            drainOwedHeights()
            // Not the settle itself. Where the reader ends up is written down when the view has
            // stopped moving, and a flick that ends with momentum still running has not.
            scheduleSettle()
        }

        /// Where a scroll counts as having stopped.
        ///
        /// A hundred and fifty milliseconds after the last movement of any kind, which is what
        /// `onScrollPhaseChange`'s `.idle` was for the lazy stack. It deliberately does not fire
        /// while the reader still has hold of the view: `remember` writes the pane's place, and
        /// there is no place to write down in the middle of a gesture.
        private func scheduleSettle() {
            settleWork?.cancel()
            settleWork = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self, !isLiveScrolling else { return }
                settleWork = nil
                if isSettlingResizeAtEnd {
                    putEnd()
                    reportGeometry()
                    isSettlingResizeAtEnd = false
                }
                censusOfTheScreen(settled: true)
                onSettled?()
                warmAhead()
            }
        }

        /// **Pays a row's first build before the reader arrives at it.**
        ///
        /// The one thing every build of a long night agreed on, and the reader found it himself of
        /// four of them: "for the items that i've already scrolled over, it's butter smooth". A row
        /// costs once. Nothing that made a row cheaper moved that, and nothing that changed the
        /// window moved it either, because the cost is not in the window or in the row, it is in
        /// the FIRST time a row is asked for. So it is asked for early, while the reader is still.
        ///
        /// Started on the settle, which is the only moment there is main thread time nobody is
        /// waiting on. Cancelled by the first movement of the clip view, and given up between rows
        /// rather than between passes, so a hand on the trackpad interrupts it within one row.
        ///
        /// **A pass that prepares anything schedules the next one, and that is deliberate.**
        /// Telling the table about rows above the reader moves the document, which moves the clip
        /// view, which settles again a moment later. So a reader who stops walks the preparation
        /// further up the conversation, sixty rows at a time, until a band two screens tall is
        /// entirely known. It stops there rather than running on: a pass that finds every row in
        /// the band already measured tells the table nothing, and nothing settles again.
        private func warmAhead() {
            warmWork?.cancel()
            warmWork = Task { @MainActor [weak self] in
                await self?.warmTheRowsAbove()
            }
        }

        /// Measures the rows just above the screen, one at a time, until the reader moves.
        ///
        /// **Measured rather than drawn, and that is the safety of it.** `measure` builds a
        /// hosting view of its own, reads a height and throws it away; it does not go through
        /// `viewFor`, so it cannot put a cell on the screen, cannot make a row draw before its
        /// turn, and cannot leave anything behind that a later pass would treat as a drawn row.
        /// What it buys is everything except the graph: the parse caches are filled, the height is
        /// exact when the reader arrives, and the correction that would have moved the document
        /// under them has already happened while nothing was moving.
        private func warmTheRowsAbove() async {
            guard let tableView, let scrollView, heights.isReady,
                  let sizing = heights.measure else { return }
            let visible = scrollView.contentView.documentVisibleRect
            let reach = TranscriptWarming.reach(viewport: Double(visible.height))
            let top = max(0, visible.minY - reach)
            let band = CGRect(x: 0, y: top, width: 1, height: visible.minY - top)
            guard band.height > 1 else { return }
            let found = tableView.rows(in: band)
            guard found.length > 0 else { return }
            let rows = TranscriptWarming.worthWarming(
                found.location..<(found.location + found.length)
            )
            var moved = IndexSet()
            // Nearest first: a reader scrolling up meets the bottom of the band, so a pass that
            // ran the other way would prepare the rows they reach last.
            for row in rows.reversed() where entries.indices.contains(row) {
                guard !Task.isCancelled, !isHeld, !isLiveScrolling else { break }
                let entry = entries[row]
                // **The streaming tail must never be measured here.** It draws nothing between
                // turns, and a nought filed against it is the one number that would silence it:
                // `viewFor` hands back no view for a row measured at nothing, and a running turn
                // would have nowhere to appear. The other three that re-render themselves are
                // excluded for the same reason. See `TranscriptEntryID.redrawsItself`.
                guard !entry.id.redrawsItself else { continue }
                let key = entry.contentKey
                guard heights.height(for: key) == nil || heights.isStale(key) else { continue }
                let taken = heights.note(
                    measure(entry, at: CGFloat(sizing.width)), for: key, shape: entry.shape
                )
                if taken { moved.insert(row) }
                // Between rows rather than after all of them, so the cost of being interrupted is
                // one row rather than sixty.
                await Task.yield()
            }
            guard !moved.isEmpty, !isHeld else { return }
            // `willStartLiveScroll` can arrive after the final yielded measurement and before this
            // point, while `clipMoved` has not yet had a chance to cancel the warming task. Keep
            // every height already learned, but hand its table correction to the same queue drawn
            // rows use so background preparation never moves the document under a hand.
            if Task.isCancelled || isLiveScrolling {
                for row in moved where entries.indices.contains(row) {
                    owedHeights.insert(entries[row].id)
                }
                drainOwedHeights()
                return
            }
            // The heights of rows ABOVE the reader, so telling the table moves everything below
            // them, which is the whole document under the screen. Anchored, exactly as a
            // correction landing during a scroll is, and cheaper here because nothing is moving.
            let wasAtEnd = isFollowingAlong
            let anchor = anchorEntry()
            noteHeights(moved)
            keepPlace(wasAtEnd: wasAtEnd, anchor: anchor)
            reportGeometry()
        }

        /// A width change that was NOT held.
        ///
        /// `TranscriptHoldView` catches every one a hand causes and freezes this view's scroll view
        /// rather than letting it through, so what is left here is the pane arriving at its first
        /// width and anything that resizes the transcript without going through that view at all.
        /// The wait is what it always was, and it is a fallback rather than the mechanism now.
        @objc private func paneResized() {
            guard !isHeld else { return }
            guard let sizing = heights.measure,
                  !TranscriptRowHeights.isSameWidth(Double(columnWidth), sizing.width) else {
                reportGeometry()
                return
            }
            resizeWork?.cancel()
            resizeWork = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self, !isHeld else { return }
                rewidth()
            }
            reportGeometry()
        }

        // MARK: - Being held while a pane is resized

        /// A hold has begun. What it is holding is the whole of the difference.
        ///
        /// **An arrival stops nothing**, because the work it is waiting for is this pane's own
        /// rows landing: stashing those would be holding out for the thing being held for. What it
        /// holds is the drawing, which is `TranscriptHoldView`'s alone.
        func holdBegan(_ held: TranscriptHoldView.Held) {
            guard held == .whatIsDrawn else { return }
            isHeld = true
            // **Where the reader is, read now rather than when the hold lets go.**
            //
            // Letting go is itself a frame change: the scroll view takes the pane's new size in
            // one step, and a pane made shorter puts the end of the content below a reader who was
            // sitting on it. `clipMoved` sees that and drops the standing instruction, so a reader
            // who had not moved at all would be anchored back to their top row by a drag. Nothing
            // under them moves while the hold is on, so this answer is still true when it is used.
            heldPlace = HeldPlace(wasAtEnd: isFollowingAlong, anchor: anchorEntry())
            // Queued against the width being left behind, and picked up again by `rewidth`.
            resizeWork?.cancel()
            resizeWork = nil
            // Measured against a width this pane is about to stop being.
            warmWork?.cancel()
            warmWork = nil
            // **Taken out of flight and KEPT, and throwing it away was a bug the reader could
            // see.** These are heights the cache has already taken from rows that were drawn: the
            // table is the only thing that has not been told. Dropping them left it believing a
            // row was shorter than it draws, for ever, because nothing asks twice. A cell that
            // already holds its content never reports again, `note` calls the same number no news,
            // and `measureExactly` skips any row the cache knows, so every mechanism that could
            // have put it right declines to.
            //
            // What that looks like is one bug with two faces. In the middle of a conversation the
            // row spills over the one beneath it, because a cell does not clip and `HostedRow`
            // draws from the top down. At the END of it there is no row beneath, so the spill goes
            // under the composer, and the document is short by exactly the difference, so the
            // scroller will not travel to it: the last line of an answer cannot be read at all.
            //
            // Kept rather than applied here, because a hold that really is a width change makes
            // them worthless: they were measured against the width being left. `holdEnded` knows
            // which kind it was.
            owedWork?.cancel()
            owedWork = nil
        }

        @discardableResult
        func holdEnded(_ held: TranscriptHoldView.Held) -> Bool {
            isHeld = false
            // A reflow either way. An arrival has usually not changed the width and finds nothing
            // to do, which is what makes it honest to run the same line for both: the question
            // "is this pane a different width from the one these heights were taken at" has one
            // answer wherever it is asked.
            let moved = rewidth()
            // **The width did not move, so everything the hold took out of flight is still true.**
            // A reflow tells the table about every row and supersedes them; no reflow tells it
            // about none, and the corrections a hold interrupted would otherwise be lost. That is
            // the reader's own report: a resize, and then a row drawn through the row above it, or
            // a last line that cannot be scrolled to. See `holdBegan`.
            if !moved { drainOwedHeights() }
            // After the width, so this pass finds the cache already declared for the new one and
            // deals with the rows that changed rather than with all of them.
            if let whileHeld {
                self.whileHeld = nil
                apply(
                    entries: whileHeld.entries,
                    scale: whileHeld.scale,
                    environment: whileHeld.environment
                )
            }
            return moved
        }

        /// Held no longer, and nothing to lay out: the rows this was holding belong to a
        /// conversation the pane has already left. The width change it was holding is picked up by
        /// `paneResized` on the next layout pass, which is a beat later and outside a view update.
        func holdCancelled() {
            isHeld = false
            whileHeld = nil
            heldPlace = nil
            // Nothing here reflows, so anything the hold took out of flight is owed by this file
            // and by nobody else. See `holdBegan`.
            drainOwedHeights()
        }

        var reducesMotion: Bool { rowEnvironment?.reduceMotion ?? false }

        // MARK: - Being pointed at another conversation

        /// **The pane has a different conversation in it, so it draws nothing until that one is
        /// ready.** See `TranscriptHoldView.hold(_:)`, and `arrived` for what ends it.
        ///
        /// The pane's FIRST conversation is held too, and that is what covers a split: splitting a
        /// tab rebuilds both panes (see `CenterPanesView`), so the chat arrives in a pane that has
        /// never drawn anything, exactly as it does in a window that has only just opened. Holding
        /// it means the split itself is drawn on the frame it was asked for and the conversation
        /// fades in behind it, rather than the whole column waiting for a transcript to lay out.
        func showing(session: SessionID, in view: TranscriptHoldView) {
            holdView = view
            guard shownSession != session else { return }
            shownSession = session
            // Nothing in the reuse pool belongs to this conversation, whatever key it says it
            // holds. See `cellGeneration`.
            cellGeneration += 1
            // **And nothing the conversation being left measured says how tall this one's rows
            // are.** The heights themselves stay, which is what makes coming back free; the mean
            // taken from them does not. See `TranscriptRowHeights.showing`, which carries the
            // eight screens of blank a prose conversation left behind it.
            heights.showing(session)
            view.hold(.nothing)
        }

        /// The conversation is in and in the right place. See `TranscriptTableController.arrived`.
        func arrived() { holdView?.ready() }

        /// **The transcript, laid out at the width the drag left the pane at.**
        ///
        /// What is on screen is measured exactly and every other row keeps the height it had.
        /// Emptying the cache is a fresh `NSHostingView` per row, which on an 1,855 row session is
        /// about four seconds of main thread: moving that from every frame of the drag to the end
        /// of the drag would not have removed it, it would have moved it to the moment the hand
        /// lifts. So the rows the reader can see are put right before the fade starts, and the
        /// rest are corrected by `noted` when they are drawn, which already outranks anything
        /// measured off screen. See `TranscriptRowHeights.rewidth`.
        @discardableResult
        private func rewidth() -> Bool {
            let held = heldPlace
            heldPlace = nil
            guard heights.rewidth(to: Double(columnWidth)) else { return false }
            // Both read before anything moves under the reader, which for a hold was before it
            // began. See `keepPlace` and `holdBegan`.
            let wasAtEnd: Bool
            let anchor: (id: TranscriptEntryID, delta: CGFloat)?
            if let held {
                wasAtEnd = held.wasAtEnd
                anchor = held.anchor
            } else {
                wasAtEnd = isFollowingAlong
                anchor = anchorEntry()
            }
            // **Before the measuring, and that is not tidiness.** A user bubble is capped at a
            // share of the pane's width, and the pane publishes that cap through this report. Rows
            // measured before it lands would be measured against the width the pane used to be,
            // and every bubble on screen would be corrected a moment later, during the fade.
            reportGeometry()
            let eager = TranscriptPaneHold.eager(visible: visibleRows, count: entries.count)
            measureExactly(eager)
            noteHeights(IndexSet(integersIn: entries.indices))
            // **The standing instruction rather than a movement, for a reader who was at the end.**
            //
            // A movement is short of the end the moment anything below it changes size, and a
            // reflow is followed by a burst of exactly that: every cell it redraws reports its own
            // height a turn or two later. Reported as "sometimes I get placed a little higher and
            // can't reach the bottom anymore". The instruction is self-releasing, so a reader who
            // scrolls away in the next moment is not pinned: see `clipMoved`.
            if wasAtEnd, !isFollowerDriving, !isLiveScrolling {
                holdsEnd = true
                isSettlingResizeAtEnd = true
                scheduleSettle()
            }
            keepPlace(wasAtEnd: wasAtEnd, anchor: anchor)
            reportGeometry()
            // And once more on the next turn, for the reason `goToEnd` says the end twice: a table
            // lays out a height change on the pass after it is told about it, so a placement made
            // on this one is resolved against numbers that are still moving.
            placeWork?.cancel()
            placeWork = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self, !isLiveScrolling else { return }
                placeWork = nil
                keepPlace(wasAtEnd: wasAtEnd, anchor: anchor)
                reportGeometry()
            }
            TranscriptHoldCensus.released(estimated: heights.staleCount)
            return true
        }

        /// Measures these rows now, at the width the cache is for, and says which of them moved.
        ///
        /// A row is measured here if nobody has measured it at all, if what is held for it was
        /// taken at another width, or if it is one of the entries whose key cannot say what it
        /// draws. Everything else is already the answer, and the rule for which is which is
        /// `TranscriptRowHeights.needsMeasuring`, which carries the blank this used to leave under
        /// the newest row.
        ///
        /// Over any sequence of row indices rather than a range, because a pass with a handful of
        /// changed keys has an `IndexSet` and its rows are not next to each other.
        @discardableResult
        private func measureExactly(_ rows: some Sequence<Int>) -> IndexSet {
            guard let sizing = heights.measure else { return IndexSet() }
            var moved = IndexSet()
            for row in rows where entries.indices.contains(row) {
                let entry = entries[row]
                guard heights.needsMeasuring(
                    entry.contentKey, redrawsItself: entry.id.redrawsItself
                ) else { continue }
                let height = measure(entry, at: CGFloat(sizing.width))
                // **A row that was expected to draw something and came out at nothing.** Recorded
                // rather than refused, because refusing it is a change to what the cache believes
                // and this is here to find out what is happening first. One of these is a row the
                // reader never sees again: nought is remembered as an answer, so `viewFor` will
                // not build it and `needsMeasuring` will not ask again. See
                // `TranscriptHoldCensus.silenced`, and `ComposerProbe`, which is reading it.
                if height == 0, !entry.drawsNothing {
                    noteSilence(row: row, entry: entry, source: "measureExactly")
                }
                let taken = heights.note(height, for: entry.contentKey, shape: entry.shape)
                if taken { moved.insert(row) }
            }
            return moved
        }

        /// **The screen a placement is about to show, measured exactly before it is shown.**
        ///
        /// Nothing is measured up front, so the table's idea of where a row is comes from an
        /// estimate until somebody looks at it. That is safe for the rows above the reader, which
        /// are corrected as they are drawn and anchored while they are; it is not safe for the
        /// screen the reader is being put on, because a placement resolved against an estimate
        /// lands where the estimate said rather than where the row is. So every placement measures
        /// its own landing first.
        ///
        /// A screen either side of it as well, so that a small scroll after arriving does not land
        /// on an estimate either.
        private func measureLanding(at y: CGFloat) {
            guard let tableView, let scrollView, heights.isReady else { return }
            let viewport = scrollView.contentView.bounds.height
            guard viewport > 1 else { return }
            let rect = CGRect(x: 0, y: max(0, y - viewport), width: 1, height: viewport * 3)
            let range = tableView.rows(in: rect)
            guard range.length > 0 else { return }
            let rows = range.location..<(range.location + range.length)
            measureExactly(rows)
            // Every row of the landing, not only the ones this pass measured. A row whose height
            // the cache already knows and the table does not is exactly the bug this file shipped,
            // and re-asking sixty rows for a number they already have costs nothing.
            noteHeights(IndexSet(integersIn: rows))
        }

        /// The rows the pane can see, in the entries' own indices.
        private var visibleRows: Range<Int> {
            guard let tableView, let scrollView else { return 0..<0 }
            let range = tableView.rows(in: scrollView.contentView.documentVisibleRect)
            guard range.length > 0 else { return 0..<0 }
            return range.location..<(range.location + range.length)
        }

        private func reportGeometry() {
            onGeometry?(currentGeometry)
        }

        // MARK: - What a probe is allowed to ask

        /// One row silenced, with the pane it was measured against.
        ///
        /// The geometry rather than the count, because "how many" is a number that says a bug
        /// happened and "at what viewport" is the one that says which frame did it. Two reads of
        /// the clip view, on a path that has just laid out a hosting view, so the cost is not a
        /// thing to weigh.
        private func noteSilence(row: Int, entry: TranscriptTableEntry, source: String) {
            let clip = scrollView?.contentView
            TranscriptHoldCensus.silenced(TranscriptHoldCensus.Silence(
                row: row,
                source: source,
                shape: String(describing: entry.shape),
                columnWidth: Double(columnWidth),
                viewportWidth: Double(clip?.bounds.width ?? 0),
                viewportHeight: Double(clip?.bounds.height ?? 0)
            ))
        }

        /// **What the cache and the table each believe about these rows.**
        ///
        /// For `ComposerProbe` and for nothing else. The transcript going blank is rows silenced
        /// one at a time rather than a pane that went dark, so the report that can answer it is a
        /// row by row table and no counter is a substitute for one. A row with `known` nought and
        /// `drawsNothing` false is a row the reader has lost.
        ///
        /// Nothing here is a measurement: every field is a lookup or a rect the table already
        /// holds. It is called twice per run, while the pane is standing still.
        func rowFacts(for rows: some Sequence<Int>) -> [RowFact] {
            rows.compactMap { row in
                guard entries.indices.contains(row) else { return nil }
                let entry = entries[row]
                return RowFact(
                    row: row,
                    name: String(describing: entry.id),
                    shape: String(describing: entry.shape),
                    drawsNothing: entry.drawsNothing,
                    known: heights.height(for: entry.contentKey),
                    assumed: heights.assumed(
                        for: entry.contentKey, shape: entry.shape, drawsNothing: entry.drawsNothing
                    ),
                    measuredNothing: heights.measuredNothing(entry.contentKey),
                    needsMeasuring: heights.needsMeasuring(
                        entry.contentKey, redrawsItself: entry.id.redrawsItself
                    ),
                    told: Double(tableView?.rect(ofRow: row).height ?? 0),
                    top: Double(tableView?.rect(ofRow: row).minY ?? 0),
                    hasCell: tableView?.view(atColumn: 0, row: row, makeIfNecessary: false) != nil
                )
            }
        }

        /// **How many heights the cache is holding, and what it is holding them for.**
        ///
        /// The number that tells an emptying from a miss. `forget` and `reset` take every measured
        /// height away in one go, and afterwards every row is answered from the mean, which is a
        /// document of the wrong length rather than a cache with a hole in it. A step of a drag
        /// where this falls to nothing is a step that emptied it, and the width beside it says
        /// which of the two did.
        var heightCacheCount: Int { heights.count }
        var heightCacheWidth: Double { heights.measure?.width ?? 0 }
        var heightCacheIsReady: Bool { heights.isReady }

        /// The rows the pane can see, for a probe that has no business knowing how that is worked
        /// out. See `visibleRows`.
        var visibleRowRange: Range<Int> { visibleRows }

        /// One row, as a probe reads it.
        struct RowFact: Sendable {
            var row: Int
            /// The entry id as text, for a person reading the report. Not an id: nothing looks a
            /// row up by it, which is why it is not `TranscriptEntryID`.
            var name: String
            var shape: String
            /// What `TranscriptRowInk` expected before anything was drawn.
            var drawsNothing: Bool
            /// What has been measured, or nothing if nobody has measured it. Nought here with
            /// `drawsNothing` false is the silence.
            var known: Double?
            /// What the table is told, which is `known` when there is one.
            var assumed: Double
            var measuredNothing: Bool
            var needsMeasuring: Bool
            /// What the table is actually drawing the row at now.
            var told: Double
            /// Where the row starts in the document, so a report can add the heights up against
            /// what the reader can see. A document taller than the content it draws is the gap.
            var top: Double
            /// Whether the table is holding a cell for it, which a silenced row never is.
            var hasCell: Bool
        }
    }
}

/// What every cell hosts, and the only place the drawn height is known.
///
/// **`fixedSize` vertically is the whole of it.** A hosting view pinned to the four edges of its
/// cell proposes the ROW's height to the root inside it, and a root that takes what it is offered
/// can never report that the row is the wrong size: it is squeezed or padded with blank and says
/// nothing either way. Fixed vertically, the content takes its own ideal height and the geometry
/// reader behind it has a number worth sending back.
///
/// The transaction is the SwiftUI half of "the animations get in the way". A recycled cell is
/// handed a different row, and any implicit animation turns that swap into a height or an opacity
/// travelling from the last row's to this one's, which over a scrolling table reads as the whole
/// transcript sliding about. Cleared here rather than in the row views, which are shared with
/// everything else that draws a transcript row. `ArrivingRow`'s settle survives it, because an
/// explicit `withAnimation` creates a transaction rather than inheriting one.
///
/// ## Known unverified: what `.global` means inside here
///
/// `ToolRowHeader` and `UserTurnRowView` report a chip's `frame(in: .global)` and
/// `TranscriptHoverOverlay` subtracts its own to place the popover. Under the lazy stack both were
/// in one hosting view, so the subtraction was right by construction; here the row is in a hosting
/// view per cell, and if SwiftUI resolves `.global` against that rather than the window every card
/// appears near the top left of the pane at the chip's x. Not photographed either way. The fix, if
/// it is wrong, is for the cell to convert, since it is the only thing that knows where it is.
/// Reproduction, from the dev database: workspace "#362 Lay the app-side styling foundation on
/// the", session `369a630d`, file chips in user bubbles at seq 387 and 948.
private struct HostedRow: View {
    let content: AnyView
    let report: @MainActor (CGFloat) -> Void
    /// Whether this copy is the one in a cell, which has a row's height to fill, or the one being
    /// measured, which has none. Everything else about the two is identical on purpose: a
    /// measurement taken through a different set of modifiers from the one that draws is a
    /// measurement that can disagree with what is on screen.
    var fills = true

    var body: some View {
        // **The stack is what makes an empty row report.** Sixty per cent of a real session is
        // rows that draw nothing: a stream event, a tool result whose call is on the row above.
        // Modifiers on a view whose body is empty lay nothing out, so the reader behind it never
        // appeared and nought was never reported, and those rows kept the running mean for ever:
        // three or four of them between two one line Bash rows is the hundred points of blank this
        // was reported for. A stack is a container and lays out at nothing, which is a height.
        let measured = VStack(alignment: .leading, spacing: 0) { content }
            // One centred reading column for every row kind. The content inside can still align
            // leading or trailing, but it does so inside the same measure as the rest of the
            // conversation. On a narrow pane this frame naturally shrinks to the available width.
            .frame(maxWidth: TranscriptLayout.conversationMeasure, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onChange(of: proxy.size.height, initial: true) { _, height in
                            report(height)
                        }
                }
            )
        return Group {
            if fills {
                // Drawn from its top down, so a row the table has made too short shows its
                // beginning and loses its end, rather than showing its end and clipping its
                // first line off the top of the cell.
                measured.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                measured
            }
        }
        .transaction { $0.animation = nil }
    }
}

/// The one root type every cell's hosting view holds.
///
/// **`NSHostingView<AnyView>` was a different underlying type per row kind.** `entry.content()` is
/// an `AnyView` over `TranscriptRowView`, `TurnFooterView`, `UserTurnRowView`,
/// `PendingTurnRowView`, `WorkspaceEventsView`, `StreamingTailView` or `TranscriptFoldRowView`,
/// and assigning a root view of a different underlying type is a different view arriving rather
/// than the same view with new inputs, so a recycled cell tore its whole graph down and built
/// another instead of updating the one it had. Timed on the census's own clock: 0.114ms a rebuild
/// against 0.066ms with the outer type held still.
///
/// The `AnyView` INSIDE stays, and has to: no concrete type spans those seven, and the closure that
/// builds one of them is what keeps a pass over four thousand entries to four thousand closures.
/// What this fixes is the type SwiftUI reads to decide what kind of update it is making.
///
/// Every field is optional because a cell exists before it holds a row, and a cell holding no row
/// draws nothing at all.
private struct TranscriptCellRoot: View {
    var content: AnyView?
    var id: TranscriptEntryID?
    var environment: TranscriptRowEnvironment?
    var report: (@MainActor (CGFloat) -> Void)?

    var body: some View {
        if let content, let id, let environment {
            HostedRow(content: content, report: { height in report?(height) })
                // A recycled cell is handed an unrelated row, and without an identity SwiftUI
                // treats that as the same view changing rather than a different view arriving,
                // which is what gives it something to animate between. It is also what makes
                // `onAppear` fire for the arrival settle. See `HostedRow`.
                .id(id)
                .transcriptRowEnvironment(environment)
        }
    }
}

/// One row of the table: an `NSHostingView` and the key of what is in it.
///
/// The hosting view is exactly the row, so there is no second opinion about its height. What the
/// content wants instead comes back through `HostedRow`, measured by the same layout that drew it.
///
/// **Pinned on all four edges, and it was briefly a frame set in `layout`.** A profile of an upward
/// scroll spent 726 samples of 3,034 inside `-[NSView _layoutSubtreeWithOldSize:]`, which is every
/// live cell sitting in the Auto Layout engine, and a frame is the same geometry with no solver in
/// it. Then a reader resized a pane and got rows drawn over one another, and the constraints came
/// back, because the saving was small and unmeasured on its own while text over text is the app
/// looking broken.
///
/// It was never proved to be the cause: nothing in the width path changed that night, so a row can
/// be drawn at a height measured for another width either way. It was reverted on the shape of the
/// risk rather than on evidence, and the evidence is a build with this line changed and nothing
/// else. If that build overlaps too, the fault is older than the mask and this can come back.
final class TranscriptTableCell: NSView {
    private let host: NSHostingView<TranscriptCellRoot>
    private var appliedKey: TranscriptContentKey?
    /// Which generation of the table's cells this one is from. Nothing to start with, so a cell
    /// built here is always behind and is always applied. See `Coordinator.cellGeneration`.
    private var appliedGeneration: Int?
    private var unclip: Task<Void, Never>?
    /// The content a height was measured for goes back with it, because an entry id alone does
    /// not say which conversation it belongs to. See `Coordinator.noted`.
    var onHeightChange: (@MainActor (TranscriptEntryID, TranscriptContentKey, CGFloat) -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        host = NSHostingView(rootView: TranscriptCellRoot())
        super.init(frame: .zero)
        self.identifier = identifier
        // **The window's safe area is not a transcript row's.** A hosting view resolves the safe
        // area from wherever it is, so a cell near the top of the pane could be laid out inside an
        // inset the row it is drawing knows nothing about, while the copy that measured that row
        // has no window and therefore no inset at all. Two answers for one row is the whole class
        // of bug this file is about. `safeAreaRegions` is the supported way to say it, and it is
        // what `_disableSafeArea` was reached for before there was one.
        host.safeAreaRegions = []
        // **Nothing here needs the hosting view's own size**, and each option it is asked for is a
        // layout measurement it has to perform: its own documentation says so. The cell pins this
        // view to its four edges below and the table decides the height, so an intrinsic content
        // size, a minimum and a maximum are three answers nobody reads. The height a row reports
        // does not come from here either: it comes from the geometry reader inside `HostedRow`,
        // over the content at its own ideal size. `DetailSplitViewController` and `TitleBarStrip`
        // make the same call for the same reason.
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not in a nib") }

    /// Returns whether the root view had to be replaced, which is the expensive half and the only
    /// half worth timing. See `TranscriptHoldCensus.cellSeconds`.
    @discardableResult
    func apply(
        entry: TranscriptTableEntry, environment: TranscriptRowEnvironment, generation: Int
    ) -> Bool {
        // The recycling. A cell that already holds this content is left exactly as it is, which
        // is what a table buys over a stack that rebuilds every realised row on every pass. The
        // three entries that re-render themselves are NOT excepted, and used to be: handing the
        // streaming tail a new root view on every pass rebuilt it several times a second.
        //
        // **The key alone was not enough, and both ways it was not enough were bugs the reader
        // could see.** See `Coordinator.cellGeneration`: a cell from the conversation the pane has
        // left can come back for the same singleton key, and a cell built in an environment that
        // has since moved is what a reload was supposed to replace.
        guard appliedKey != entry.contentKey || appliedGeneration != generation else { return false }
        appliedKey = entry.contentKey
        appliedGeneration = generation
        let id = entry.id
        // Captured beside the id, so a height that arrives late says what it was measured for
        // rather than only which row reported it. See `Coordinator.noted`.
        let key = entry.contentKey
        // One concrete root type, whatever the row is. See `TranscriptCellRoot`.
        host.rootView = TranscriptCellRoot(
            content: entry.content(),
            id: id,
            environment: environment,
            report: { [weak self] height in self?.onHeightChange?(id, key, height) }
        )
        return true
    }

    /// Clips this cell for as long as its row is travelling to a new height.
    ///
    /// See `Coordinator.noteHeights(_:over:)` for why this is on for the length of a fold and off
    /// the rest of the time.
    func clips(whileGrowingFor seconds: Double) {
        unclip?.cancel()
        clipsToBounds = true
        unclip = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.clipsToBounds = false
            self?.unclip = nil
        }
    }
}
