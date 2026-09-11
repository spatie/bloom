import SwiftUI
import BloomCore

/// One line of a run, with everything the row around it needs to be drawn.
struct DiffRunLine: Equatable {
    /// Nil is a row with nothing opposite it in the side by side layout.
    var line: DiffLine?
    var carry: LexState = LexState()
    var emphasis: [Range<String.Index>] = []
    /// Whether a pending review comment is anchored here, which tints the row as under
    /// discussion the way the band under it is.
    var isCommented: Bool = false
}

/// Several diff lines share one native text view so selections and navigation span a run.
struct DiffRunView: View, Equatable {
    var lines: [DiffRunLine]
    var language: Language
    var numbers: DiffGutter.Numbers = .both
    /// Total width of the run, including gutters. Fixed by the file's widest line so the whole
    /// diff scrolls horizontally as one sheet.
    var width: CGFloat
    var wrappedHeights: [CGFloat]?
    var lookupRevision = 0
    var onLookup: ((CodeTextView, Int, Bool, Bool, Bool) -> Void)?
    var destination: CodeLocation?
    /// Opens the review comment editor at a line. Nil, the default, draws no `+` at all.
    var onComment: ((ReviewSpot) -> Void)?
    /// A drag from one row's `+`, reporting where it began and which line it has reached. Where
    /// that is comes from `DiffDragRange`, in the core: this run is a block of rows exactly
    /// `CodeMetrics.rowHeight` apart, which is the same invariant the hover and the gutter rest
    /// on, so counting rows off the travel is as true as a hit test would be.
    var onDragComment: ((ReviewSpot, ReviewSpot) -> Void)?
    /// The pointer let go, so the editor opens on whatever the drag selected.
    var onEndCommentDrag: (() -> Void)?
    /// Opens the in-place editor on the lines around one, by its new-side number. Nil, the
    /// default, offers nothing.
    var onEdit: ((Int) -> Void)?

    /// Which line the pointer is over, as an offset into `lines`.
    ///
    /// A run is one view where there used to be one per line, so the hover that reveals the `+`
    /// cannot be a plain `onHover` any more: it has to say WHERE. The arithmetic is only honest
    /// because every line box in here is exactly `CodeMetrics.rowHeight` tall, which is the same
    /// invariant the gutter depends on.
    ///
    /// **It is filled by `DiffRowHover` rather than by `.onContinuousHover`, and that is a fix
    /// rather than a preference.** The paragraph that used to be here said hover was the one
    /// thing a selectable `Text` might swallow over its glyphs. It does: the moved events stop at
    /// the text, the container heard one phase at the boundary and nothing after it, and the `+`
    /// never appeared on any row of any run. Since two consecutive lines are a run, that was
    /// nearly every row in every diff. The tracking area cannot be intercepted and takes no
    /// clicks, so the code underneath is still selectable.
    ///
    /// It reveals the `+` and decides nothing else. A `+` drawn on the wrong line would be
    /// visible and would still comment on the line it is drawn beside, because the button takes
    /// its spot from its own row rather than from this. That is deliberate: nothing that could
    /// act on the wrong line is allowed to depend on where a pointer is thought to be.
    @State private var hovered: Int?

    /// The same argument as `DiffLineView.==`, which is where it is written out: the closure is a
    /// fresh allocation on every pass over the diff and cannot be compared, and it does not need
    /// to be. A run is worth more here than a line was, since one of these stands in for up to
    /// `DiffRunGrouping.runLimit` rows.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.lines == rhs.lines
            && lhs.language == rhs.language
            && lhs.numbers == rhs.numbers
            && lhs.width == rhs.width
            && lhs.wrappedHeights == rhs.wrappedHeights
            && lhs.destination == rhs.destination
            && lhs.lookupRevision == rhs.lookupRevision
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let wrappedHeights {
                WrappedDiffChrome(
                    lines: lines, heights: wrappedHeights, numbers: numbers,
                    onComment: { index in
                        if let spot = spot(of: lines[index]) { onComment?(spot) }
                    },
                    onEdit: { index in
                        if let line = editableLine(of: lines[index]) { onEdit?(line) }
                    },
                    commentable: lines.map { spot(of: $0) != nil },
                    editable: lines.map { editableLine(of: $0) != nil }
                )
                .overlay(alignment: .topLeading) {
                    if let hovered, lines.indices.contains(hovered) {
                        commentButton(Row(id: hovered, entry: lines[hovered], isHovered: true))
                            .frame(height: CodeMetrics.rowHeight)
                            .offset(y: wrappedHeights.prefix(hovered).reduce(0, +))
                    }
                }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in chrome(row) }
                }
            }
            WrappedCodeText(
                lines: runLines, language: language,
                width: wrappedCodeWidth, heights: wrappedHeights ?? Array(repeating: CodeMetrics.rowHeight, count: lines.count),
                onComment: { index in
                    if let spot = spot(of: lines[index]) { onComment?(spot) }
                },
                onEdit: { index in
                    if let line = editableLine(of: lines[index]) { onEdit?(line) }
                },
                commentable: lines.map { spot(of: $0) != nil },
                editable: lines.map { editableLine(of: $0) != nil },
                wraps: wrappedHeights != nil,
                onLookup: onLookup,
                highlightedOffset: destinationOffset
            )
            .frame(width: wrappedCodeWidth, height: wrappedHeights?.reduce(0, +) ?? CodeMetrics.rowHeight * CGFloat(lines.count))
            .padding(.leading, columnsWidth)
            .accessibilityHidden(true)
        }
        .frame(width: width, height: wrappedHeights?.reduce(0, +) ?? CodeMetrics.rowHeight * CGFloat(lines.count), alignment: .topLeading)
        // For `DiffLineView`'s reason: most of a diff row draws nothing, and without a shape the
        // pointer finds the run only along the band of pixels the glyphs cover.
        .contentShape(Rectangle())
        // Over everything, including the code, and hit testable by nothing. See `DiffRowHover`.
        .overlay {
            DiffRowHover(rowHeight: CodeMetrics.rowHeight, rowCount: lines.count,
                         rowHeights: wrappedHeights) { hovered = $0 }
        }
    }

    // MARK: - Per line chrome

    /// One row of the run as the loop below sees it, with the hover IN THE DATA.
    ///
    /// **That is the fix for "the + still does not follow the pointer", and it was measured.**
    /// The loop used to be `ForEach(lines.indices)` reading `hovered` inside the closure. On a
    /// crossing, `body` ran with the new value, and the rows did not: logging every body pass and
    /// every overlay evaluation gave 123 state writes against 2 rebuilds of a row. Nothing in the
    /// `ForEach`'s data had changed, so SwiftUI kept the children it already had, and the one
    /// thing that HAD changed was a value read inside the closure where the diff cannot see it.
    /// Carried as a stored property of the element, a hovered row is a changed element, and the
    /// row is rebuilt because it genuinely differs.
    private struct Row: Identifiable, Equatable {
        /// The line's offset into `lines`, which is also its identity within the run.
        var id: Int
        var entry: DiffRunLine
        var isHovered: Bool
    }

    private var rows: [Row] {
        lines.indices.map { Row(id: $0, entry: lines[$0], isHovered: hovered == $0) }
    }

    /// Everything about one line that is not its code: the washes, the numbers, the marker, the
    /// spoken sentence and the `+`. Full width, and drawn under the code layer.
    private func chrome(_ row: Row) -> some View {
        let entry = row.entry
        return HStack(spacing: 0) {
            DiffGutter(line: entry.line, numbers: numbers)
            DiffMarker(line: entry.line)
            Spacer(minLength: 0)
        }
        .frame(height: CodeMetrics.rowHeight)
        .frame(width: width, height: wrappedHeights?[row.id] ?? CodeMetrics.rowHeight, alignment: .topLeading)
        // Collapsed here, above the overlay and never below it, for the reason spelled out on
        // `DiffLineView` and on `DiffCommentButton`: `children: .ignore` swallows every descendant
        // of what it is applied to, and a `+` inside the collapsed element is one no keyboard and
        // no screen reader can reach.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DiffGutter.speech(for: entry.line))
        .accessibilityHidden(entry.line == nil)
        .overlay(alignment: .topLeading) { commentButton(row).frame(height: CodeMetrics.rowHeight) }
        // The same action the `+` carries, on the right click as well, and for the reason written
        // out on `DiffLineView`.
        //
        // **On the row, never on the run, and that is a safety decision rather than a tidiness
        // one.** The run knows which line the pointer is over only from `hovered`, and hover is
        // the one thing here that a selectable `Text` might swallow over its own glyphs: if it
        // does, a stale index would put "Comment on This Line" on a line nobody pointed at, and a
        // comment filed against the wrong line is worse than no menu at all. Asked of the row, the
        // answer is whatever row the click actually landed on, which is exactly what the per line
        // path has always done, or nothing, which is also what the per line path does.
        .contextMenu {
            if let spot = spot(of: entry) {
                Button("Comment on This Line") { onComment?(spot) }
            }
            // On the row for the same safety reason, and it matters more here than for the
            // comment: an edit opened against a line nobody pointed at would put a box of the
            // wrong code in front of the reader.
            if let line = editableLine(of: entry), let onEdit {
                Button("Edit These Lines") { onEdit(line) }
            }
        }
        // Over the diff wash, not instead of it: an addition under review stays an addition, and
        // the amber says "under discussion" on top of whatever the line already was.
        .background(entry.isCommented ? Palette.reviewLine : .clear)
        .background(DiffWash.background(of: entry.line))
        // Padding opposite a longer run on the other side. From the marker's leading edge, not
        // from the row's, which is where `DiffLineView` starts it: the numbers keep the pane's own
        // ground so the two layouts have the same gutter.
        .background(alignment: .trailing) {
            if entry.line == nil {
                Rectangle()
                    .fill(Palette.surfaceSunken)
                    .frame(width: max(0, width - DiffGutter.width(for: numbers)))
            }
        }
    }

    @ViewBuilder
    private func commentButton(_ row: Row) -> some View {
        if let onComment, let spot = spot(of: row.entry) {
            DiffCommentButton(
                spot: spot,
                isRowHovered: row.isHovered,
                onComment: onComment,
                onDrag: drag(from: spot, at: row.id),
                onDragEnd: onEndCommentDrag
            )
        }
    }

    /// A drag from one row's `+`, in points of travel, answered with the line it has reached.
    ///
    /// The row it began on is passed as an index rather than looked up from the hover, for the
    /// reason the context menu above is attached per row: hover is the one thing a selectable
    /// `Text` can swallow, and nothing that could act on the wrong line is allowed to depend on
    /// where a pointer is thought to be.
    private func drag(from spot: ReviewSpot, at index: Int) -> ((CGFloat) -> Void)? {
        guard let onDragComment else { return nil }
        return { travel in
            guard let target = DiffDragRange.spot(
                from: index,
                translation: travel,
                rowHeight: CodeMetrics.rowHeight,
                rowHeights: wrappedHeights,
                spots: dragSpots,
                side: spot.side
            ) else { return }
            onDragComment(spot, target)
        }
    }

    /// What each row of this run offers a drag, in drawn order.
    ///
    /// Filtered through `DiffCommentSpot` exactly as the `+` itself is, so a drag can only ever
    /// reach a line this pane would have offered a button on. In the split layout that is what
    /// keeps a range inside one half rather than jumping the hairline to a line wearing the same
    /// number on the other side.
    private var dragSpots: [ReviewSpot?] {
        lines.map { DiffCommentSpot.offered(for: $0.line, numbers: numbers, enabled: true) }
    }

    // MARK: - Geometry

    /// Where the code starts: both gutters in the unified layout, one in either half of the split,
    /// plus the marker column. The one number the code layer needs, and it is arithmetic rather
    /// than a measurement for the same reason the sheet's width is.
    private var destinationOffset: Int? {
        guard let destination else { return nil }
        var offset = 0
        for entry in lines {
            if let line = entry.line, line.kind != .deletion, line.newNumber == destination.line {
                return offset + min(destination.column - 1, max(0, line.text.utf16.count - 1))
            }
            offset += (entry.line?.text.utf16.count ?? 0) + 1
        }
        return nil
    }

    private var wrappedCodeWidth: CGFloat {
        floor(max(1, width - columnsWidth - CodeMetrics.gutterPadding))
    }

    private var columnsWidth: CGFloat {
        DiffGutter.width(for: numbers) + CodeMetrics.markerWidth
    }

    // MARK: - Commenting

    private func spot(of entry: DiffRunLine) -> ReviewSpot? {
        DiffCommentSpot.offered(for: entry.line, numbers: numbers, enabled: onComment != nil)
    }

    private func editableLine(of entry: DiffRunLine) -> Int? {
        DiffEditTarget.offered(for: entry.line, numbers: numbers, enabled: onEdit != nil)
    }

    // MARK: - Code

    private var runLines: [CodeRunLine] {
        lines.map { entry in
            CodeRunLine(
                // A row with nothing opposite it still occupies a line in the run, or every line
                // below it in the split layout would sit one row too high. Shortened for drawing
                // only: see `DiffLineDisplay`.
                text: DiffLineDisplay.text(entry.line?.text ?? ""),
                carry: entry.carry,
                emphasis: entry.emphasis,
                emphasisColor: DiffWash.emphasis(of: entry.line)
            )
        }
    }
}
