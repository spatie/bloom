import AppKit
import BloomCore
import QuartzCore
import SwiftUI

/// The transcript, drawn by an `NSTableView`.
///
/// **Why not a `LazyVStack`, which is what this replaced.** SwiftUI cannot be told how tall an
/// unrealised row is, so a `ScrollView` over a lazy stack guesses for every row it has not built
/// and corrects as they come into view. Measured on an 1,855 message session, the content height
/// fell from 48,995 points to 17,339 during a single scroll pass, a resize over it ran at eight
/// frames a second, and a reader's place could not be put back because the offset it was written
/// down against no longer named the same row. A table knows every row's height, caches it, keeps
/// the scroll position stable when a height changes, recycles the views, and scrolls to a row
/// exactly. Measured against each other on an idle machine, twice each: 13.6 frames a second on a
/// resize against 6.6 to 11.4, 110ms of main thread per second of streaming against 275, half the
/// worst scroll frame, and a reader put back where they were on four returns out of four where the
/// stack returned them to the top of the conversation every time.
///
/// **The bargain, which is the finding rather than a detail:** the table has to be TOLD each
/// height, and the only thing that knows a SwiftUI row's height is a laid out `NSHostingView`. So
/// the heights are measured off screen, one measurement per row per width, and cached. That cost
/// is paid up front whenever the table is reloaded, and again whenever the pane's width changes,
/// which are exactly the two moments the lazy stack was cheapest. `TranscriptRowHeights` in the
/// core is the cache and carries the rules; this file is the AppKit around it.
///
/// The width case is handled by not handling it during the gesture: a live resize leaves every
/// cached height alone, and the whole cache is rebuilt once, anchored, a beat after the drag
/// stops. So a resize is cheap and wrong for a moment, rather than expensive and right.
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
    /// every pass threw that state away and rebuilt the tail several times a second. Their heights
    /// come from the cache like everything else and are corrected by what the cell actually drew,
    /// which is a mechanism these three need and nothing else has to pay for.
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
    /// This is the table's answer to `ScrollPosition(edge: .bottom)`, which is what the lazy stack
    /// used and which was a standing instruction rather than a movement: SwiftUI reapplied it on
    /// every layout pass that grew the content, so a row landing kept the reader at the end in the
    /// same pass that made the content taller. An AppKit scroll view has nothing of the sort. A
    /// single `setBoundsOrigin` is a movement, and a movement is short of the end the moment
    /// anything below it changes size, which in a transcript is constantly: heights are corrected
    /// after a row has been drawn, the streaming tail grows between rows, and a window that has
    /// just been moved to the tail has not been laid out yet when the scroll is issued.
    ///
    /// So the instruction is held. Every place in the coordinator that can change where the end is
    /// re-asserts it, and it is let go of by `releaseEnd` and by the reader taking hold of the
    /// view. See `Coordinator.holdsEnd`.
    func goToEnd() { coordinator?.goToEnd() }

    /// Lets go of the standing instruction above, without moving anything.
    func releaseEnd() { coordinator?.releaseEnd() }

    /// **`TranscriptLiveEndFollower` is driving the clip view from here on, so nothing in the
    /// table may touch it.**
    ///
    /// Two things move the view at the live end while a turn streams: the follower's display link,
    /// which takes the view back by what arrived and eases forward again so the movement can be
    /// followed, and this file, which puts the view at the end the instant a height is corrected.
    /// Both running is the two of them fighting, one at 120Hz and one per correction, and what
    /// reaches the screen is the instant pin with the travel invisible underneath it. That is the
    /// same argument `TranscriptLiveEndFollower.onStart` carries about `ScrollPosition`, and it
    /// arrives here for the same reason: the follower is the only one of the two that can make a
    /// movement the eye can read, so it wins for as long as it is running.
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
/// fence are each drawn inside a `ScrollView(.horizontal)` so a wide one can be pushed sideways,
/// and SwiftUI backs that with a real `NSScrollView` of its own, `SwiftUI.HostingScrollView`. Over
/// the lazy stack there was a SwiftUI scroll view above it, which it knows about and hands a
/// vertical wheel straight to. Here there is not, so it falls through to `NSScrollView`'s own
/// `scrollWheel(with:)` and the answer becomes AppKit's: a scroll view that is already at its edge
/// in an axis keeps the event and scrolls elastically **unless a responder above it has asked for
/// one**, and `NSResponder.wantsForwardedScrollEvents(for:)` is false by default, which the header
/// documents and the runtime confirms: asked on macOS 27, a plain `NSScrollView` answers false for
/// both axes. Nothing asked, so a wheel over a table rubber-banded the table and left the
/// transcript standing still.
///
/// Asking is the whole fix. AppKit forwards only from an inner view already at its edge in that
/// axis, which for one with nothing to scroll vertically is always, and it decides the event's
/// predominant axis itself, so a mostly-horizontal wheel stays with the table it is over and a wide
/// table still scrolls sideways. One answer here covers everything that scrolls horizontally inside
/// a row, tables and code fences alike, rather than each of them having to fend off a gesture it
/// never wanted.
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
    /// This is `onScrollPhaseChange` in the shape the lazy stack had it, and it is a real answer
    /// rather than the debounce the spike used. A debounce over "the clip view moved" cannot tell
    /// a hand from this app's own travel, so the jump pill's glide reported itself as a scroll on
    /// its very first frame and the pane's handler stopped it: the press moved the transcript by a
    /// few points and left it there, with the completion that would have landed it at the end
    /// never run. `NSScrollView` posts `willStartLiveScroll` and `didEndLiveScroll` for
    /// user-initiated scrolling only, so this app's own movement is silent here and the follower
    /// pauses for a hand and for nothing else.
    let onLiveScrollChange: @MainActor (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
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
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        controller.coordinator = coordinator
        coordinator.onGeometry = onGeometryChange
        coordinator.onSettled = onSettled
        coordinator.onLiveScrollChange = onLiveScrollChange
        coordinator.apply(entries: entries, scale: scale, environment: rowEnvironment)
    }

    // MARK: - The coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
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

        /// The width a row is actually drawn at, which is the TABLE's width and not the clip
        /// view's.
        ///
        /// **This was half of the wrong heights.** With legacy scrollers the clip view is fifteen
        /// points wider than the document inside it, so every measurement was taken at a width no
        /// row is ever laid out at: a paragraph measured at the wider figure wraps to fewer lines
        /// than it draws at, and the row comes out short with its first line clipped off the top.
        /// One column and no intercell spacing, so the table's width is the cell's width.
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

            // A reader who is following along is kept at the end, which is what a `ScrollPosition`
            // standing at `.bottom` did for the lazy stack. `holdsEnd` is the same thing said out
            // loud by something that asked for it; `wasAtEnd` is the reader who simply has not
            // scrolled away. Everything else keeps the ROW that was at the top of the pane, which
            // is the thing a point offset cannot do and the whole reason for the table.
            let wasAtEnd = ScrollEnd.isAtEnd(
                contentHeight: currentGeometry.contentHeight,
                viewportHeight: currentGeometry.viewportHeight,
                offset: currentGeometry.offset
            )
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

            if holdsEnd || (wasAtEnd && !isFollowerDriving) {
                putEnd()
            } else if let anchor {
                restore(anchor)
            }
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
            if let cached = heights.height(for: entry.contentKey) { return cached }
            let measured = TranscriptRowHeights.rounded(measure(entry, at: sizing.width))
            heights.note(measured, for: entry.contentKey)
            return measured
        }

        /// A fresh `NSHostingView` per measurement, at the exact width the cell is laid out at.
        ///
        /// **The other half of the wrong heights, and it is worth writing down what the shortcut
        /// cost.** One hosting view reused for every row, with its size invalidated by hand, gave
        /// a long conversation several hundred points of blank between rows: an `NSHostingView`
        /// keeps its own fitting size, and `invalidateIntrinsicContentSize` followed by
        /// `layoutSubtreeIfNeeded` does not reliably make it forget the row before. A fresh one
        /// has no previous answer to hand back. It builds a whole SwiftUI graph per row, which is
        /// the expensive thing this arrangement can afford: 2.1ms a layout pass against the lazy
        /// stack's 11.9ms.
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
                let wasAtEnd = ScrollEnd.isAtEnd(
                    contentHeight: currentGeometry.contentHeight,
                    viewportHeight: currentGeometry.viewportHeight,
                    offset: currentGeometry.offset
                )
                // **The row being corrected is usually above the reader**, which is why this needs
                // the same anchor `apply` takes. Scrolling up through a long conversation brings
                // rows into view at the top, each of them is drawn and reports a height that
                // differs from what it was measured at, and every one of those corrections moves
                // everything below it. Without the anchor the text slides under the eye on the way
                // up, which is the one thing a reader notices immediately.
                let anchor = anchorEntry()
                noteHeights(rows)
                // **The correction is also what leaves a reader short of the end**, and it is the
                // second half of "the pill does not go all the way down": a scroll that was right
                // when it was issued is short the moment a row below the fold turns out to be
                // taller than it was measured at. So the end is said again after every batch.
                if holdsEnd || (wasAtEnd && !isFollowerDriving) {
                    putEnd()
                } else if let anchor {
                    restore(anchor)
                }
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
        /// **The height a fold changes is the TABLE's, not the row's**, which is the whole reason
        /// this has to be said at all. In the lazy stack a `withAnimation` around the state change
        /// carried into the `if` inside `ToolRowView` and the row grew itself. Here the row is
        /// remeasured and the table is told a number, and a number arriving is not a transition.
        /// So the travel is the table's row-height animation, at the length `TranscriptMotion`
        /// gives every other settle in this app.
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

        // MARK: Scrolling

        var currentGeometry: TranscriptTableGeometry {
            guard let scrollView, let document = scrollView.documentView else {
                return TranscriptTableGeometry()
            }
            let clip = scrollView.contentView
            return TranscriptTableGeometry(
                offset: clip.bounds.origin.y,
                contentHeight: document.bounds.height,
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
            // **And once more on the next turn, which is the table's version of the two-call dance
            // the lazy stack needed.** There the two calls existed because `ScrollPosition` is a
            // value and naming the edge it already stood at was not a change SwiftUI could apply.
            // That argument is obsolete: a call on a table always acts. What is not obsolete is
            // the reason the second call landed anything, which is that the content this one is
            // aimed at may not have been laid out yet. A window that has just been moved to the
            // tail, a bubble drawn on the frame Return was pressed, a row inserted in the same
            // update: each of them changes where the end is after this line has read it.
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
            guard let scrollView, let document = scrollView.documentView else { return }
            // The only number that means the end. A row being *visible* is not it: the last row of
            // a transcript is often taller than the pane. See `TranscriptAnchor`.
            put(
                TranscriptAnchor.end(
                    contentHeight: document.bounds.height,
                    viewportHeight: scrollView.contentView.bounds.height
                ),
                in: scrollView
            )
        }

        func scroll(to entryID: TranscriptEntryID, anchor: UnitPoint) {
            // Somewhere that is not the end, so whatever asked to be at the end has been overruled.
            aimingElsewhere()
            put(at: entryID, anchor: anchor)
            // **And once more on the next turn, for the same reason `goToEnd` says the end twice.**
            //
            // A row is scrolled to at the height the table currently believes it is, and that
            // belief is corrected the moment the row is drawn. The setup log is where this shows:
            // unfolding 1,381 lines of it and asking to be taken to the end of it lands at the
            // height the folded row was measured at, thousands of points short of where the log
            // now ends. The correction arrives one turn later, and so does this.
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
                contentHeight: scrollView.documentView?.bounds.height ?? 0,
                viewportHeight: clip.bounds.height
            )
            guard abs(clip.bounds.origin.y - target) > 0.01 else { return }
            // So that the escape in `clipMoved` does not read this file's own arrival at the end
            // as the reader scrolling away from it.
            isPutting = true
            clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: target))
            scrollView.reflectScrolledClipView(clip)
            isPutting = false
        }

        /// The three ways the table is told rows moved, each with a name of its own **so that the
        /// next `sample` can tell them apart**. Which branch a scroll actually takes was the one
        /// thing an earlier profile could not say: `apply` was 47.7 per cent of the main thread
        /// with `NSHostingView` under it and `measure` at half a per cent, which is a reload
        /// rebuilding cells rather than heights being taken, but only if the shape really was
        /// `.rebuilt`. Three symbols answer that without a probe having to carry a counter.
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
                TranscriptAnchor.delta(
                    rowTop: tableView.rect(ofRow: row).minY, viewportTop: visible.minY
                )
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

        /// **Nothing is remeasured while the pane is being resized.**
        ///
        /// Every cached height was taken at a width that no longer holds, so all of them are wrong
        /// the moment the divider moves, and taking them again is a hosting view per row per frame
        /// of the drag. So the drag runs on stale heights, which is visibly wrong for any row whose
        /// text rewraps, and the whole cache is rebuilt once when the hand comes off, anchored on
        /// the row at the top so the correction does not move the reader.
        @objc private func paneResized() {
            guard let sizing = heights.measure, abs(columnWidth - sizing.width) > 0.5 else {
                reportGeometry()
                return
            }
            resizeWork?.cancel()
            resizeWork = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self else { return }
                guard heights.reset(width: columnWidth, scale: sizing.scale) else { return }
                let anchor = anchorEntry()
                noteHeights(IndexSet(integersIn: entries.indices))
                // A resize moves the end as much as it moves anything, so a reader who asked to be
                // at it is still owed it.
                if holdsEnd {
                    putEnd()
                } else if let anchor {
                    restore(anchor)
                }
                reportGeometry()
            }
            reportGeometry()
        }

        private func reportGeometry() {
            onGeometry?(currentGeometry)
        }
    }
}

/// What every cell hosts, and the only place the drawn height is known.
///
/// **`fixedSize` vertically is the whole of it.** A hosting view pinned to the four edges of its
/// cell proposes the ROW's height to the SwiftUI root inside it, and a root that takes what it is
/// offered can never report that the row is the wrong size: it is squeezed, or it is padded with
/// blank, and it says nothing either way. Fixed vertically, the content takes the width it is
/// given and its own ideal height, the reader sees the row it should have had even before the
/// correction lands, and the geometry reader behind it has a number worth sending back.
///
/// The transaction is the SwiftUI half of "the animations get in the way". A cell is recycled: the
/// same hosting view is handed a different row, and any implicit animation inside turns that swap
/// into a height or an opacity travelling from what the last row was to what this one is, which
/// over a scrolling table reads as the whole transcript sliding about. It is cleared here, at the
/// root of the hosted content, because the row views themselves are shared with everything else
/// that draws a transcript row and must not be touched.
///
/// **The arrival settle survives it**, and that is not an accident of ordering. `ArrivingRow`
/// animates from its own `onAppear` with an explicit `withAnimation`, which is a transaction it
/// creates rather than one it inherits, so clearing the inherited one takes nothing away from it.
/// See `RowArrival`, which measured why the fade has to be started by the cell rather than aimed
/// at it.
///
/// ## Known unverified: what `.global` means inside here
///
/// **A hover card is positioned by two views agreeing about one coordinate space, and they are no
/// longer certainly in the same one.** `ToolRowHeader` and `UserTurnRowView` report the chip's
/// `frame(in: .global)` to `TranscriptHoverHost`, and `TranscriptHoverOverlay` subtracts its own
/// `frame(in: .global)` to place the popover. Under the lazy stack both were inside one hosting
/// view, so whatever `.global` resolved to, it resolved to the same thing twice and the
/// subtraction was right by construction. Here the overlay is still in the pane's hierarchy and
/// the row is in a hosting view of its own per cell, and if SwiftUI resolves `.global` against the
/// hosting view rather than the window then the row's answer is its own offset within the cell,
/// the subtraction is nonsense, and every card appears near the top left of the pane at the chip's
/// x. If it resolves against the window, nothing has changed and this note can go.
///
/// It has not been photographed either way, so it is written down rather than guessed at. The fix,
/// if it is wrong, is not to fiddle with `.global`: it is for the cell to convert, since the cell
/// is the only thing that knows where it is. `HostedRow` would name a coordinate space, the
/// reporters would use it, and an object in the environment carrying the cell's own view would do
/// the `convert(_:to: nil)`. Reproduction, from the dev database: workspace "#362 Lay the app-side
/// styling foundation on the", session `369a630d`, file chips in user bubbles at seq 387 and 948.
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
        // The recycling. A cell that already holds this content is left exactly as it is, which is
        // what a table buys over a stack that rebuilds every realised row on every pass.
        //
        // The three entries that re-render themselves are NOT excepted, and used to be. The
        // streaming tail and the setup log watch their own state and re-render inside the cell;
        // handing them a new root view on every pass threw that state away and rebuilt the tail
        // several times a second.
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
