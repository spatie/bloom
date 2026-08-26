import AppKit
import BloomCore
import SwiftUI

/// The transcript drawn by an `NSTableView` instead of a `LazyVStack`. **Spike, and it is ugly.**
///
/// What it is here to find out: SwiftUI cannot be told how tall an unrealised row is, so a
/// `ScrollView` over a lazy stack guesses for every row it has not built and corrects as they come
/// into view. Measured on an 1,855 message session, the content height falls from 48,995 points to
/// 17,339 during a single scroll pass, a resize over it runs at eight frames a second, and a
/// reader's place cannot be put back because the offset it was written down against no longer
/// names the same row. A table knows every row's height, caches it, keeps the scroll position
/// stable when a height changes, recycles the views and scrolls to a row exactly.
///
/// The bargain, which is the finding rather than a detail: the table has to be TOLD each height,
/// and the only thing that knows a SwiftUI row's height is a laid out `NSHostingView`. So the
/// heights are measured off screen, one measurement per row per width, and cached. That cost is
/// paid up front whenever the table is reloaded, and again whenever the pane's width changes,
/// which are exactly the two moments the lazy stack is cheapest.
///
/// The width case is handled by not handling it during the gesture: a live resize leaves every
/// cached height alone, and the whole cache is rebuilt once, anchored, a beat after the drag stops.
/// So a resize is cheap and wrong for a moment, rather than expensive and right.
struct TranscriptTableEntry: Identifiable {
    /// Stable across passes: `row.<seq>` for a stored row, and a fixed string for each of the
    /// things that are not stored rows.
    let id: String
    /// Everything about the entry that can change what it draws, and therefore how tall it is.
    /// The height cache is keyed on this, so a row whose key has not moved is never remeasured and
    /// a cell holding it is never rebuilt.
    let contentKey: String
    /// Whether this entry re-renders itself from its own observation rather than from a pass over
    /// the list: the streaming tail, the setup log, the delivery at the head of the queue.
    ///
    /// It no longer decides anything about the height, and that is the fix rather than a tidy-up.
    /// A live entry used to be remeasured off screen on every call and handed a new root view on
    /// every pass; now every entry's height comes from the cache and is corrected by what the cell
    /// actually drew, which is a mechanism these three need and nothing else has to pay for.
    let isLive: Bool
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
}

/// The handle the list keeps on the table, for the three things it has to be able to do to it: go
/// to the end, go to a row by name, and go to a point.
@MainActor
final class TranscriptTableController {
    fileprivate weak var coordinator: TranscriptTable.Coordinator?

    var scrollView: NSScrollView? { coordinator?.scrollView }

    func scrollToEnd() { coordinator?.scrollToEnd() }
    func scroll(to entryID: String, anchor: UnitPoint) {
        coordinator?.scroll(to: entryID, anchor: anchor)
    }
    func scroll(toY y: CGFloat) { coordinator?.scroll(toY: y) }
    /// The entry at the top of the pane, which is the place a reader is put back at.
    var topmostEntryID: String? { coordinator?.topmostEntryID }
    var geometry: TranscriptTableGeometry {
        coordinator?.currentGeometry ?? TranscriptTableGeometry()
    }
}

struct TranscriptTable: NSViewRepresentable {
    let entries: [TranscriptTableEntry]
    let controller: TranscriptTableController
    /// The text scale the rows are drawn at. Part of the height cache's key, because the same row
    /// at a different scale is a different height.
    let scale: CGFloat
    let onGeometryChange: @MainActor (TranscriptTableGeometry) -> Void
    /// A scroll has stopped moving. Where the pane writes down where the reader is.
    let onSettled: @MainActor () -> Void
    /// A scroll is happening at all, which is what takes a hover card down.
    let onScrollStarted: @MainActor () -> Void

    /// The whole environment, carried across the AppKit gap by hand.
    ///
    /// An `NSHostingView` built inside a coordinator is not a child of anything in SwiftUI's tree,
    /// so it inherits nothing: no hover host, no bubble cap, no link actions, no `AppModel`, no
    /// colour scheme. Reading the environment here and re-applying it whole to every hosted row is
    /// the shortest thing that works. It is also why every pass over this list takes an edge on
    /// every environment value, which a production version would have to narrow.
    @Environment(\.self) private var environment

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

        let scroll = NSScrollView()
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
        // worse bug than a transcript with no air above its first row. Spike: put the padding on
        // the first and last entries instead.

        context.coordinator.attach(table: table, scroll: scroll)
        controller.coordinator = context.coordinator
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        controller.coordinator = coordinator
        coordinator.onGeometry = onGeometryChange
        coordinator.onSettled = onSettled
        coordinator.onScrollStarted = onScrollStarted
        coordinator.environment = environment
        coordinator.apply(entries: entries, scale: scale)
    }

    // MARK: - The coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private(set) var entries: [TranscriptTableEntry] = []
        private var index: [String: Int] = [:]
        var environment = EnvironmentValues()
        var onGeometry: (@MainActor (TranscriptTableGeometry) -> Void)?
        var onSettled: (@MainActor () -> Void)?
        var onScrollStarted: (@MainActor () -> Void)?

        weak var tableView: NSTableView?
        weak var scrollView: NSScrollView?

        /// Height by cache key. Never cleared by a reload, which is the whole point: the document
        /// is the same height after a row lands as it was before, so nothing under the reader
        /// moves, and the number a reader's place was written down against still means something.
        private var heights: [String: CGFloat] = [:]
        private var width: CGFloat = 0
        private var scale: CGFloat = 1
        private var settleWork: Task<Void, Never>?
        private var resizeWork: Task<Void, Never>?
        private var isScrolling = false
        /// Rows whose height turned out to be wrong once they were drawn, batched so a pass over
        /// the visible rows costs one `noteHeightOfRows` rather than one each.
        private var owedHeights = IndexSet()
        private var owedWork: Task<Void, Never>?

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
            NotificationCenter.default.addObserver(
                self, selector: #selector(clipMoved),
                name: NSView.boundsDidChangeNotification, object: scroll.contentView
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(paneResized),
                name: NSView.frameDidChangeNotification, object: scroll
            )
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        // MARK: Entries

        func apply(entries newEntries: [TranscriptTableEntry], scale newScale: CGFloat) {
            guard let tableView else { return }
            // The first width the table ever has. Until it arrives every measurement is one point
            // tall, and a table told one point per row is a transcript that is not there. Anything
            // cached against nought goes with it.
            var widthArrived = false
            if width == 0, columnWidth > 1 {
                width = columnWidth
                heights.removeAll()
                widthArrived = true
            }
            if newScale != scale {
                scale = newScale
                heights.removeAll()
                widthArrived = true
            }

            let sameShape = newEntries.count == entries.count
                && zip(newEntries, entries).allSatisfy { $0.id == $1.id }
            var changed = IndexSet()
            if sameShape {
                for (offset, pair) in zip(newEntries, entries).enumerated()
                where pair.0.contentKey != pair.1.contentKey {
                    changed.insert(offset)
                }
            }

            let wasAtEnd = isAtEnd
            let anchor = sameShape ? nil : anchorEntry()

            entries = newEntries
            index = [:]
            for (offset, entry) in newEntries.enumerated() { index[entry.id] = offset }

            if sameShape {
                if widthArrived { noteHeights(IndexSet(entries.indices)) }
                if !changed.isEmpty {
                    noteHeights(changed)
                    tableView.reloadData(
                        forRowIndexes: changed, columnIndexes: IndexSet(integer: 0)
                    )
                } else if !widthArrived {
                    // Nothing at all has moved. Not even a geometry report is owed.
                    return
                }
            } else {
                tableView.reloadData()
            }

            // A row landing while the reader is at the end keeps them at the end, which is what a
            // `ScrollPosition` standing at `.bottom` did for the lazy stack. Everything else keeps
            // the ROW that was at the top of the pane, which is the thing a point offset cannot do
            // and the whole reason for this spike.
            if wasAtEnd {
                scrollToEnd()
            } else if let anchor {
                restore(anchor)
            }
            // Off this pass, because this one runs inside `updateNSView` and what it calls writes
            // SwiftUI state. Reporting from here is "Modifying state during view update".
            Task { @MainActor [weak self] in self?.reportGeometry() }
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard entries.indices.contains(row) else { return 1 }
            return height(of: entries[row])
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        func tableView(
            _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
        ) -> NSView? {
            guard entries.indices.contains(row) else { return nil }
            let entry = entries[row]
            let identifier = NSUserInterfaceItemIdentifier("bloom.transcript.cell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self)
                as? TranscriptTableCell ?? TranscriptTableCell(identifier: identifier)
            cell.onHeightChange = { [weak self] id, height in
                self?.noted(height: height, for: id)
            }
            cell.apply(entry: entry, environment: environment)
            return cell
        }

        // MARK: Heights

        private func cacheKey(_ entry: TranscriptTableEntry) -> String {
            "\(entry.contentKey)#\(Int(width))#\(scale)"
        }

        /// The cache, and a fresh measurement when it misses.
        ///
        /// Live entries read the cache like everything else now. They used to be measured on every
        /// call, which is a whole hosting view per layout pass for the streaming tail; what keeps
        /// them right instead is `noted` below, which is authoritative and which the tail triggers
        /// itself as it grows.
        private func height(of entry: TranscriptTableEntry) -> CGFloat {
            let key = cacheKey(entry)
            if let cached = heights[key] { return cached }
            let measured = measure(entry)
            heights[key] = measured
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
        /// the expensive thing this spike now knows it can afford: 2.1ms a layout pass against the
        /// lazy stack's 11.9ms.
        ///
        /// The width is a required CONSTRAINT rather than a frame, because that is what makes
        /// `fittingSize` solve the layout at that width instead of handing back the unwrapped
        /// ideal width of a paragraph.
        private func measure(_ entry: TranscriptTableEntry) -> CGFloat {
            guard width > 1 else { return 1 }
            let host = NSHostingView(rootView: AnyView(
                HostedRow(content: entry.content(), report: { _ in }, fills: false)
                    .environment(\.self, environment)
            ))
            host.translatesAutoresizingMaskIntoConstraints = false
            let constraint = host.widthAnchor.constraint(equalToConstant: width)
            constraint.isActive = true
            host.layoutSubtreeIfNeeded()
            let height = host.fittingSize.height
            constraint.isActive = false
            // A row that measures as nothing is a measurement that failed rather than a row with
            // no height, and a transcript of zero height rows is unusable. One line is wrong by
            // less than that.
            guard height > 1 else { return TranscriptLayout.rowHeight * scale }
            return height.rounded(.up)
        }

        /// **What the row turned out to be when it was drawn, which outranks anything measured off
        /// screen.**
        ///
        /// The number arriving here is the ideal height of the same content, laid out by the same
        /// SwiftUI, at the width the cell was actually given. There is nothing better to know, so
        /// the cache is overwritten rather than consulted: a measurement that disagrees with what
        /// is on screen is a wrong measurement, whichever of the two was taken first.
        ///
        /// It is also what keeps the streaming tail growing. Nothing in the list body watches the
        /// per-token buffers, on purpose, so the only thing that knows the tail got taller is the
        /// tail, and this is how it says so.
        private func noted(height: CGFloat, for entryID: String) {
            guard let row = index[entryID], entries.indices.contains(row) else { return }
            let key = cacheKey(entries[row])
            let rounded = height.rounded(.up)
            guard rounded > 1, abs((heights[key] ?? 0) - rounded) > 0.5 else { return }
            heights[key] = rounded
            owedHeights.insert(row)
            guard owedWork == nil else { return }
            owedWork = Task { @MainActor [weak self] in
                guard let self else { return }
                owedWork = nil
                let rows = owedHeights
                owedHeights = IndexSet()
                guard !rows.isEmpty else { return }
                let wasAtEnd = isAtEnd
                noteHeights(rows)
                if wasAtEnd { scrollToEnd() }
                reportGeometry()
            }
        }

        /// Every height change in this file goes through here.
        ///
        /// **`noteHeightOfRows(withIndexesChanged:)` animates.** It is the AppKit half of "the
        /// animations get in the way": a row correcting its height slides the whole document under
        /// the reader over a quarter of a second, and a transcript correcting several does it
        /// several times over. There is nothing to watch in a measurement being put right.
        private func noteHeights(_ rows: IndexSet) {
            guard let tableView, !rows.isEmpty else { return }
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            tableView.noteHeightOfRows(withIndexesChanged: rows)
            NSAnimationContext.endGrouping()
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

        private var isAtEnd: Bool {
            let geometry = currentGeometry
            return ScrollEnd.isAtEnd(
                contentHeight: geometry.contentHeight,
                viewportHeight: geometry.viewportHeight,
                offset: geometry.offset
            )
        }

        var topmostEntryID: String? {
            guard let tableView, let scrollView else { return nil }
            let visible = scrollView.contentView.documentVisibleRect
            let range = tableView.rows(in: visible)
            guard range.length > 0, entries.indices.contains(range.location) else { return nil }
            return entries[range.location].id
        }

        func scrollToEnd() {
            guard let scrollView, let document = scrollView.documentView else { return }
            put(document.bounds.height, in: scrollView)
        }

        func scroll(to entryID: String, anchor: UnitPoint) {
            guard let tableView, let scrollView, let row = index[entryID] else { return }
            let rect = tableView.rect(ofRow: row)
            let clip = scrollView.contentView
            let y: CGFloat
            if anchor == .center {
                y = rect.midY - clip.bounds.height / 2
            } else if anchor == .bottom {
                y = rect.maxY - clip.bounds.height
            } else {
                y = rect.minY
            }
            put(y, in: scrollView)
        }

        func scroll(toY y: CGFloat) {
            guard let scrollView else { return }
            put(y, in: scrollView)
        }

        private func put(_ y: CGFloat, in scrollView: NSScrollView) {
            let clip = scrollView.contentView
            let document = scrollView.documentView?.bounds.height ?? 0
            let limit = max(0, document - clip.bounds.height)
            clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: min(max(0, y), limit)))
            scrollView.reflectScrolledClipView(clip)
        }

        /// The row at the top of the pane and how far above it the viewport starts, so a growth
        /// that adds rows above the reader can put them back on the same ROW rather than at the
        /// same point.
        private func anchorEntry() -> (id: String, delta: CGFloat)? {
            guard let tableView, let scrollView, let id = topmostEntryID,
                  let row = index[id] else { return nil }
            let visible = scrollView.contentView.documentVisibleRect
            return (id, tableView.rect(ofRow: row).minY - visible.minY)
        }

        private func restore(_ anchor: (id: String, delta: CGFloat)) {
            guard let tableView, let scrollView, let row = index[anchor.id] else { return }
            put(tableView.rect(ofRow: row).minY - anchor.delta, in: scrollView)
        }

        @objc private func clipMoved() {
            if !isScrolling {
                isScrolling = true
                onScrollStarted?()
            }
            reportGeometry()
            settleWork?.cancel()
            settleWork = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self else { return }
                isScrolling = false
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
            guard columnWidth > 1, abs(columnWidth - width) > 0.5 else {
                reportGeometry()
                return
            }
            resizeWork?.cancel()
            resizeWork = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self else { return }
                let newWidth = columnWidth
                guard newWidth > 1 else { return }
                width = newWidth
                heights.removeAll()
                let anchor = anchorEntry()
                noteHeights(IndexSet(entries.indices))
                if let anchor { restore(anchor) }
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
/// root of the hosted content, because the row views themselves are shared with the lazy stack and
/// must not be touched.
private struct HostedRow: View {
    let content: AnyView
    let report: @MainActor (CGFloat) -> Void
    /// Whether this copy is the one in a cell, which has a row's height to fill, or the one being
    /// measured, which has none. Everything else about the two is identical on purpose: a
    /// measurement taken through a different set of modifiers from the one that draws is a
    /// measurement that can disagree with what is on screen, which is the bug this pass is fixing.
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
    var onHeightChange: (@MainActor (String, CGFloat) -> Void)?

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

    func apply(entry: TranscriptTableEntry, environment: EnvironmentValues) {
        // The recycling. A cell that already holds this content is left exactly as it is, which is
        // what a table buys over a stack that rebuilds every realised row on every pass.
        //
        // A live entry is NOT excepted, and used to be. The streaming tail and the setup log watch
        // their own state and re-render themselves inside the cell; handing them a new root view on
        // every pass threw that state away and rebuilt the tail several times a second.
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
            // gives it something to animate between. See `HostedRow`.
            .id(id)
            .environment(\.self, environment)
        )
    }
}
