import BloomCore

/// A flattened render list. Building it once per state change, rather than deriving it inside
/// `body`, keeps a fifty thousand line diff from walking its own hunks on every layout pass.
///
/// Identity is the content, never the position. These rows carried a running counter as an id,
/// and every rebuild (expanding a run, revealing a gap, a band arriving or leaving) renumbered
/// the whole list, so a row kept its number while its content became a different line: hover and
/// the `+` button's focus stayed with the number and landed on another line, and a lazy stack
/// diffed an insertion as every row below it mutated in place. A line already knows itself by
/// `DiffLine.index`, unique across the parsed diff and negative for revealed gap lines, and the
/// other kinds carry names of their own.
enum DiffRow: Identifiable {
    case header(hunk: Int, text: String)
    case runExpander(runID: Int, hidden: Int)
    case gapExpander(gapID: Int, hidden: Int)
    case line(DiffLine)
    case pair(SideBySideRow)
    /// Consecutive lines drawn as one block of selectable text. See `DiffRunView`: a `Text` per
    /// line cannot be selected across two of them, which is the bug this case exists for.
    case lineRun([DiffLine])
    /// The same, for the side by side layout, where each half is its own block.
    case pairRun([SideBySideRow])
    /// A pending review comment, drawn under the line it is about, or at the top of the diff
    /// when `ReviewPlacements` could not put it under one.
    case commentBand(ReviewPlacement)
    /// The comment being written, under the line the `+` was pressed on. One at a time, so the
    /// constant id is unique, and a draft that moves keeps its identity, which is the point:
    /// the half-typed text must survive the move.
    case commentEditor(ReviewSpot)
    /// The lines being edited in place, under the last of them. One at a time per file, for the
    /// same reason and with the same constant id as the comment editor above: the box has to keep
    /// its identity through a rebuild, or the text in it is thrown away by a poll.
    case lineEditor(DiffEditRegion)

    var id: String {
        switch self {
        case let .header(hunk, _): "header-\(hunk)"
        case let .runExpander(runID, _): "run-\(runID)"
        case let .gapExpander(gapID, _): "gap-\(gapID)"
        case let .line(line): "line-\(line.index)"
        // Either side names the pair: `DiffLine.index` is global to the parsed diff, and the
        // pair's own `index` is not, restarting per hunk in the one-hunk folds the split view
        // builds from.
        case let .pair(row): "pair-\(row.left?.index ?? row.index)-\(row.right?.index ?? .min)"
        // Named after the row it starts on, which a run keeps while it grows or shrinks. Content
        // changes are not identity's job here: `DiffRunView` is `Equatable` and redraws on them.
        case let .lineRun(lines): "linerun-\(lines.first?.index ?? .min)"
        // Both sides name it, for the reason the single pair above gives and which a run needs
        // just as much: the pair's own `index` restarts per hunk, so a run beginning with an
        // addition (nothing on the left) would have been "pairrun-0" in every hunk that starts
        // with one, and two rows of a `ForEach` sharing an id is a diff that draws one of them.
        case let .pairRun(rows):
            "pairrun-\(rows.first?.left?.index ?? rows.first?.index ?? .min)"
                + "-\(rows.first?.right?.index ?? .min)"
        case let .commentBand(placement): "band-\(placement.id)"
        case .commentEditor: "editor"
        case .lineEditor: "line-editor"
        }
    }

    /// Whether this row may be drawn inside a run with its neighbours.
    ///
    /// Only plain lines may. A heading, either expander, a comment band and the open editor each
    /// draw a view between two lines, and text cannot flow through one.
    ///
    /// `.noNewline` is a line and is still refused, which is the one exclusion that is not
    /// structural. That row does not draw its own text at all: it draws the words "No newline at
    /// end of file" in italics, so put in a run it would have printed whatever git left in the
    /// line instead. Rare enough that keeping it on the per line path costs a selection nothing,
    /// and it is the last line of a file anyway.
    var isRunnable: Bool {
        switch self {
        case let .line(line):
            return line.kind != .noNewline
        case let .pair(row):
            return row.left?.kind != .noNewline && row.right?.kind != .noNewline
        default:
            return false
        }
    }

    /// Collapse consecutive line rows into runs, so a selection can cross them.
    ///
    /// A post pass over the finished list rather than something the two row builders each do, and
    /// that is the point of doing it here: `unifiedRows` and `splitRows` interleave headings,
    /// expanders, bands and the editor from four different places, and a rule about what sits next
    /// to what is only reliable once all of them have had their say. Where a run stops is
    /// `DiffRunGrouping`, in the core, with the tests.
    static func grouped(_ rows: [DiffRow]) -> [DiffRow] {
        var result: [DiffRow] = []
        result.reserveCapacity(rows.count)

        for chunk in DiffRunGrouping.chunks(count: rows.count, isLine: { rows[$0].isRunnable }) {
            switch chunk {
            case let .single(index):
                result.append(rows[index])
            case let .run(range):
                let slice = Array(rows[range])
                if let lines = slice.asLines {
                    result.append(.lineRun(lines))
                } else if let pairs = slice.asPairs {
                    result.append(.pairRun(pairs))
                } else {
                    // A run of both kinds at once, which neither row builder can produce: one
                    // list is all unified or all split. Drawn as it always was rather than
                    // dropped, because a line missing off a diff is the worst thing this file
                    // could do and a run is only a convenience.
                    result.append(contentsOf: slice)
                }
            }
        }

        return result
    }
}

private extension [DiffRow] {
    var asLines: [DiffLine]? {
        var result: [DiffLine] = []
        for row in self {
            guard case let .line(line) = row else { return nil }
            result.append(line)
        }
        return result
    }

    var asPairs: [SideBySideRow]? {
        var result: [SideBySideRow] = []
        for row in self {
            guard case let .pair(pair) = row else { return nil }
            result.append(pair)
        }
        return result
    }
}
