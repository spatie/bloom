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
    let contentKey: String
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

    /// **`TranscriptLiveEndFollower` is driving the clip view from here on, so nothing in the
    /// table may touch it.**
    ///
    /// Both moving the view at the live end is the two of them fighting, one at 120Hz and one per
    /// height correction, and what reaches the screen is the instant pin with the travel invisible
    /// underneath it. The follower is the only one that can make a movement the eye can read, so
    /// it wins for as long as it is running.
    func followerTookOver() { coordinator?.followerTookOver() }

    /// The follower's link has gone down, wherever it left the view. See
    /// `TranscriptLiveEndFollower.onStop`, which carries why this cannot be `onRest`.
    func followerHandedBack() { coordinator?.followerHandedBack() }

    func scroll(to entryID: TranscriptEntryID, anchor: UnitPoint) {
        coordinator?.scroll(to: entryID, anchor: anchor)
    }
    func scroll(toY y: CGFloat) { coordinator?.scroll(toY: y) }

    /// A fold is about to open or close. See `Coordinator.pendingUnfolds`.
    func willUnfold(_ entryID: TranscriptEntryID) { coordinator?.willUnfold(entryID) }

    /// The entry at the top of the pane, which is the place a reader is put back at.
    var topmostEntry: TranscriptEntryID? { coordinator?.topmostEntry }

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
        private var resizeWork: Task<Void, Never>?
        private var endWork: Task<Void, Never>?
        private var reaimWork: Task<Void, Never>?
        /// Rows whose height turned out to be wrong once they were drawn, batched so a pass over
        /// the visible rows costs one `noteHeightOfRows` rather than one each.
        private var owedHeights = IndexSet()
        private var owedWork: Task<Void, Never>?

        /// **A standing instruction to be at the end of the conversation.** See
        /// `TranscriptTableController.goToEnd`, which carries why a single scroll cannot mean it.
        private var holdsEnd = false
        /// Whether this file is the thing moving the clip view right now, so that the escape below
        /// does not read the transcript's own arrival at the end as the reader scrolling away.
        private var isPutting = false
        /// Whether the reader has hold of the view. `NSScrollView`'s own answer, not a guess.
        private var isLiveScrolling = false
        /// Whether the follower is driving. See `TranscriptTableController.followerTookOver`.
        private var isFollowerDriving = false
        /// Rows whose next height change is a fold the reader just clicked, and may therefore be
        /// animated. Consumed by the pass that applies it. See `willUnfold`.
        private var pendingUnfolds: Set<TranscriptEntryID> = []

        /// **Whether the transcript is being held still while a pane is resized.** Nothing in here
        /// measures, reloads or moves while it is on. See `TranscriptHoldView`.
        private var isHeld = false
        /// The last pass that arrived while the transcript was held, applied when it is let go.
        /// Rows that land mid drag are held with everything else and turn up in the same fade.
        private var whileHeld:
            (entries: [TranscriptTableEntry], scale: CGFloat, environment: TranscriptRowEnvironment)?

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

            // **A new typeface or a new hover host is every cell, and every height with it.**
            // Rare, because it takes a settings change to move any of them, so a whole reload is
            // the honest answer rather than a diff of what each row happened to read. The heights
            // go with it because `chatFont` changes how a paragraph wraps and is deliberately not
            // part of what the cache is keyed on: one thing that empties it is easier to hold in
            // the head than two.
            let environmentMoved = rowEnvironment != nil && rowEnvironment != environment
            rowEnvironment = environment
            if environmentMoved { heights.forget() }

            // The first width the table ever has, and any change of text size. Until a width
            // arrives every measurement is refused, and a table told a hair per row is a
            // transcript that is not there. See `TranscriptRowHeights.reset`.
            let remeasured = heights.reset(width: columnWidth, scale: scale) || environmentMoved

            let newIDs = newEntries.map(\.id)
            let change = TranscriptEntryChange.between(ids, newIDs)

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

            if change == .same, changed.isEmpty, !remeasured {
                // Nothing at all has moved. Not even a geometry report is owed.
                return
            }

            // Both read before anything moves under the reader. See `keepPlace`.
            let wasAtEnd = isFollowingAlong
            let anchor = change.movesRows ? anchorEntry() : nil

            entries = newEntries
            ids = newIDs
            index = [:]
            for (offset, id) in newIDs.enumerated() { index[id] = offset }

            // **Rows in and out rather than `reloadData()`, and this is the whole of the scroll
            // stall.** See `TranscriptEntryChange`, which carries the measurement.
            switch change {
            case .same:
                break
            case .grew(let head, let tail):
                rowsArrived(head: head, tail: tail, in: tableView)
            case .shrank(let head, let tail):
                rowsLeft(head: head, tail: tail, in: tableView)
            case .rebuilt:
                rebuiltEverything(in: tableView)
            }

            if remeasured {
                if environmentMoved { tableView.reloadData() }
                noteHeights(IndexSet(integersIn: entries.indices))
            } else if !changed.isEmpty {
                // The cells first, so that a row whose height is about to travel already holds
                // what it is travelling to show. See `noteHeights(_:over:)`.
                tableView.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
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
            guard entries.indices.contains(row) else { return Self.hair }
            return max(Self.hair, height(of: entries[row]))
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        func tableView(
            _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
        ) -> NSView? {
            guard entries.indices.contains(row), let rowEnvironment else { return nil }
            let entry = entries[row]
            let identifier = NSUserInterfaceItemIdentifier("bloom.transcript.cell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self)
                as? TranscriptTableCell ?? TranscriptTableCell(identifier: identifier)
            cell.onHeightChange = { [weak self] id, height in
                self?.noted(height: height, for: id)
            }
            cell.apply(entry: entry, environment: rowEnvironment)
            return cell
        }

        // MARK: Heights

        /// The cache, and a fresh measurement when it misses.
        ///
        /// The three entries that re-render themselves read the cache like everything else. They
        /// used to be measured on every call, which is a whole hosting view per layout pass for
        /// the streaming tail; what keeps them right instead is `noted` below, which is
        /// authoritative and which the tail triggers itself as it grows.
        private func height(of entry: TranscriptTableEntry) -> CGFloat {
            guard let sizing = heights.measure else { return Self.hair }
            if let cached = heights.height(for: entry.contentKey) { return CGFloat(cached) }
            let measured = CGFloat(
                TranscriptRowHeights.rounded(measure(entry, at: CGFloat(sizing.width)))
            )
            heights.note(measured, for: entry.contentKey)
            return measured
        }

        /// A fresh `NSHostingView` per measurement, at the exact width the cell is laid out at.
        ///
        /// **The other half of the wrong heights.** One hosting view reused for every row, with
        /// its size invalidated by hand, gave a long conversation several hundred points of blank
        /// between rows: an `NSHostingView` keeps its own fitting size and does not reliably
        /// forget the row before. A fresh one has no previous answer to hand back, and a whole
        /// SwiftUI graph per row is what this arrangement can afford: 2.1ms a layout pass against
        /// the lazy stack's 11.9ms.
        ///
        /// The width is a required CONSTRAINT rather than a frame, because that is what makes
        /// `fittingSize` solve the layout at that width instead of handing back the unwrapped
        /// ideal width of a paragraph.
        private func measure(_ entry: TranscriptTableEntry, at width: CGFloat) -> CGFloat {
            guard let rowEnvironment else { return 0 }
            let host = NSHostingView(rootView: AnyView(
                HostedRow(content: entry.content(), report: { _ in }, fills: false)
                    .transcriptRowEnvironment(rowEnvironment)
            ))
            host.translatesAutoresizingMaskIntoConstraints = false
            let constraint = host.widthAnchor.constraint(equalToConstant: width)
            constraint.isActive = true
            host.layoutSubtreeIfNeeded()
            let height = host.fittingSize.height
            constraint.isActive = false
            // Nought is a real answer, and `TranscriptRowHeights` carries what pretending
            // otherwise cost.
            return height
        }

        /// **What the row turned out to be when it was drawn, which outranks anything measured off
        /// screen.** See `TranscriptRowHeights.note`.
        private func noted(height: CGFloat, for entryID: TranscriptEntryID) {
            // The tail goes on growing inside its frozen cell while a pane is dragged, and a
            // height taken from it would be filed against the entry list this pass is not
            // applying. It is remeasured when the hold lets go, with everything on screen.
            guard !isHeld else { return }
            guard let row = index[entryID], entries.indices.contains(row) else { return }
            guard heights.note(height, for: entries[row].contentKey) else { return }
            owedHeights.insert(row)
            guard owedWork == nil else { return }
            owedWork = Task { @MainActor [weak self] in
                guard let self else { return }
                owedWork = nil
                let rows = owedHeights
                owedHeights = IndexSet()
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
            }
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
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = seconds
            if seconds > 0 {
                NSAnimationContext.current.timingFunction =
                    CAMediaTimingFunction(name: .easeOut)
            }
            tableView.noteHeightOfRows(withIndexesChanged: rows)
            NSAnimationContext.endGrouping()
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
            endWork?.cancel()
            endWork = nil
        }

        func followerTookOver() {
            isFollowerDriving = true
            releaseEnd()
        }

        func followerHandedBack() {
            isFollowerDriving = false
        }

        private func putEnd() {
            guard let scrollView else { return }
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
            let rect = tableView.rect(ofRow: row)
            put(
                TranscriptAnchor.offset(
                    rowTop: rect.minY,
                    rowHeight: rect.height,
                    viewportHeight: scrollView.contentView.bounds.height,
                    anchor: anchor.y
                ),
                in: scrollView
            )
        }

        func scroll(toY y: CGFloat) {
            aimingElsewhere()
            guard let scrollView else { return }
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
            // So that the escape in `clipMoved` does not read this file's own arrival at the end
            // as the reader scrolling away from it.
            isPutting = true
            clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: target))
            scrollView.reflectScrolledClipView(clip)
            isPutting = false
        }

        /// The three ways the table is told rows moved, each with a name of its own **so that the
        /// next `sample` can tell them apart**. An earlier profile put `apply` at 47.7 per cent of
        /// the main thread with `NSHostingView` under it and `measure` at half a per cent, which
        /// only means a reload rebuilding cells if the shape really was `.rebuilt`.
        private func rowsArrived(head: Range<Int>, tail: Range<Int>, in tableView: NSTableView) {
            tableView.beginUpdates()
            // The head first, so that the indices the tail is named by are the indices the table
            // has by the time it hears about them. Both are indices into the NEW list, which is
            // what `TranscriptEntryChange` promises and what its own test checks by rebuilding the
            // list from them.
            if !head.isEmpty { tableView.insertRows(at: IndexSet(integersIn: head), withAnimation: []) }
            if !tail.isEmpty { tableView.insertRows(at: IndexSet(integersIn: tail), withAnimation: []) }
            tableView.endUpdates()
        }

        private func rowsLeft(head: Range<Int>, tail: Range<Int>, in tableView: NSTableView) {
            tableView.beginUpdates()
            // And the tail first here, for the same reason turned around: both are indices into
            // the OLD list, so the later run has to go before the earlier one moves it.
            if !tail.isEmpty { tableView.removeRows(at: IndexSet(integersIn: tail), withAnimation: []) }
            if !head.isEmpty { tableView.removeRows(at: IndexSet(integersIn: head), withAnimation: []) }
            tableView.endUpdates()
        }

        /// Every cell thrown away and the visible ones built again. A session being replaced, and
        /// nothing else should ever reach here.
        private func rebuiltEverything(in tableView: NSTableView) {
            tableView.reloadData()
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
            if holdsEnd, !isPutting, !currentGeometry.isAtEnd { releaseEnd() }
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
        @objc private func liveScrolled() {
            liveScrollBegan()
        }

        @objc private func liveScrollEnded() {
            guard isLiveScrolling else { return }
            isLiveScrolling = false
            onLiveScrollChange?(false)
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
                onSettled?()
            }
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

        /// Everything stops. See `TranscriptHoldView`, and `TranscriptResizeHold` for the rule.
        func holdBegan() {
            isHeld = true
            // Both were queued against the width being left behind.
            resizeWork?.cancel()
            resizeWork = nil
            owedWork?.cancel()
            owedWork = nil
            owedHeights = IndexSet()
        }

        @discardableResult
        func holdEnded() -> Bool {
            isHeld = false
            let moved = rewidth()
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

        var reducesMotion: Bool { rowEnvironment?.reduceMotion ?? false }

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
            guard heights.rewidth(to: Double(columnWidth)) else { return false }
            // Both read before anything moves under the reader. See `keepPlace`.
            let wasAtEnd = isFollowingAlong
            let anchor = anchorEntry()
            let eager = TranscriptResizeHold.eager(visible: visibleRows, count: entries.count)
            measureExactly(eager)
            noteHeights(IndexSet(integersIn: entries.indices))
            keepPlace(wasAtEnd: wasAtEnd, anchor: anchor)
            reportGeometry()
            TranscriptHoldCensus.released(measured: eager.count, estimated: heights.staleCount)
            return true
        }

        /// Measures these rows now, at the width the cache is for, and files the answers.
        private func measureExactly(_ rows: Range<Int>) {
            guard let sizing = heights.measure else { return }
            for row in rows where entries.indices.contains(row) {
                let entry = entries[row]
                guard heights.isStale(entry.contentKey) else { continue }
                heights.note(measure(entry, at: CGFloat(sizing.width)), for: entry.contentKey)
            }
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
        let measured = content
            .frame(maxWidth: .infinity, alignment: .leading)
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

/// One row of the table: an `NSHostingView` and the key of what is in it.
///
/// Pinned on all four edges, so the hosting view is exactly the row and there is no second opinion
/// about its height. What the content wants instead comes back through `HostedRow`, measured by
/// the same layout that drew it.
final class TranscriptTableCell: NSView {
    private let host: NSHostingView<AnyView>
    private var appliedKey: String?
    private var unclip: Task<Void, Never>?
    var onHeightChange: (@MainActor (TranscriptEntryID, CGFloat) -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        host = NSHostingView(rootView: AnyView(EmptyView()))
        super.init(frame: .zero)
        self.identifier = identifier
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

    func apply(entry: TranscriptTableEntry, environment: TranscriptRowEnvironment) {
        // The recycling. A cell that already holds this content is left exactly as it is, which
        // is what a table buys over a stack that rebuilds every realised row on every pass. The
        // three entries that re-render themselves are NOT excepted, and used to be: handing the
        // streaming tail a new root view on every pass rebuilt it several times a second.
        guard appliedKey != entry.contentKey else { return }
        appliedKey = entry.contentKey
        let id = entry.id
        host.rootView = AnyView(
            HostedRow(
                content: entry.content(),
                report: { [weak self] height in self?.onHeightChange?(id, height) }
            )
            // A recycled cell is handed an unrelated row, and without an identity SwiftUI treats
            // that as the same view changing rather than a different view arriving, which is what
            // gives it something to animate between. It is also what makes `onAppear` fire for the
            // arrival settle. See `HostedRow`.
            .id(id)
            .transcriptRowEnvironment(environment)
        )
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
