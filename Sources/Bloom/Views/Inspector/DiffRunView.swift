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

/// Several consecutive diff lines, drawn with ONE text object for the code so that a selection
/// runs across them.
///
/// **This is the fix for "text on multiple lines is not selectable in diff previews", reported on
/// 0.20.0.** Every line used to be its own `Text`, sibling `Text`s are separate selection scopes
/// on this system, and so a drag selected the line it began on and stopped. Nothing else about the
/// row changed: the gutter, the marker, the washes, the `+` and the spoken sentence are all still
/// one view per line, because all of them are per line facts. Only the code became one object.
///
/// ## How it stays level
///
/// The code no longer gets its height from a frame, it gets it from the text system, so the
/// columns beside it only stay level if each line box comes out at exactly `CodeMetrics.rowHeight`.
/// `CodeRunText` does that with `.lineSpacing` and half a gap of padding at each end, and both of
/// those numbers are `CodeMetrics.rowSpacing`, derived from the same font the row height is. The
/// alternative, a paragraph style on the string, is ignored outright by SwiftUI: the measurement
/// is on `CodeMetrics.rowSpacing`. Measured offscreen, seven lines came out at 126.0 points
/// against a gutter of 7 by 18.
///
/// ## Why the code is a layer over the rows rather than a column beside them
///
/// The per line chrome is drawn full width, underneath, and the code is laid over it with the
/// columns' width as leading padding. Drawn as a third column in an `HStack` instead, a row with
/// nothing opposite it could not paint `Palette.surfaceSunken` across the width the way
/// `DiffLineView` does, and the accessibility element for a line would have been the gutter
/// rather than the line. Padding rather than a clear spacer in the top layer, deliberately: a
/// `Color.clear` is hit testable and would have sat on top of the `+` button underneath it.
struct DiffRunView: View, Equatable {
    var lines: [DiffRunLine]
    var language: Language
    var numbers: DiffGutter.Numbers = .both
    /// Total width of the run, including gutters. Fixed by the file's widest line so the whole
    /// diff scrolls horizontally as one sheet.
    var width: CGFloat
    /// Opens the review comment editor at a line. Nil, the default, draws no `+` at all.
    var onComment: ((ReviewSpot) -> Void)?
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
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    chrome(row)
                }
            }
            HStack(spacing: 0) {
                CodeRunText(lines: runLines, language: language)
                    .padding(.leading, columnsWidth)
                    // The sentence a reader hears is the row's, assembled by `DiffGutter.speech`
                    // and already carrying this line's text. Left visible, VoiceOver read the
                    // whole run a second time as one undifferentiated block.
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
            }
        }
        .frame(width: width, height: CodeMetrics.rowHeight * CGFloat(lines.count), alignment: .leading)
        // For `DiffLineView`'s reason: most of a diff row draws nothing, and without a shape the
        // pointer finds the run only along the band of pixels the glyphs cover.
        .contentShape(Rectangle())
        // Over everything, including the code, and hit testable by nothing. See `DiffRowHover`.
        .overlay {
            DiffRowHover(rowHeight: CodeMetrics.rowHeight, rowCount: lines.count) { hovered = $0 }
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
        .frame(width: width, height: CodeMetrics.rowHeight, alignment: .leading)
        // Collapsed here, above the overlay and never below it, for the reason spelled out on
        // `DiffLineView` and on `DiffCommentButton`: `children: .ignore` swallows every descendant
        // of what it is applied to, and a `+` inside the collapsed element is one no keyboard and
        // no screen reader can reach.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DiffGutter.speech(for: entry.line))
        .accessibilityHidden(entry.line == nil)
        .overlay(alignment: .leading) { commentButton(row) }
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
            DiffCommentButton(spot: spot, isRowHovered: row.isHovered, onComment: onComment)
        }
    }

    // MARK: - Geometry

    /// Where the code starts: both gutters in the unified layout, one in either half of the split,
    /// plus the marker column. The one number the code layer needs, and it is arithmetic rather
    /// than a measurement for the same reason the sheet's width is.
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
                // below it in the split layout would sit one row too high.
                text: entry.line?.text ?? "",
                carry: entry.carry,
                emphasis: entry.emphasis,
                emphasisColor: DiffWash.emphasis(of: entry.line)
            )
        }
    }
}
