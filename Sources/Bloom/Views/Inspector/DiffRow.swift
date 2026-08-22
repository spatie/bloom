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
    /// A pending review comment, drawn under the line it is about, or at the top of the diff
    /// when `ReviewPlacements` could not put it under one.
    case commentBand(ReviewPlacement)
    /// The comment being written, under the line the `+` was pressed on. One at a time, so the
    /// constant id is unique, and a draft that moves keeps its identity, which is the point:
    /// the half-typed text must survive the move.
    case commentEditor(ReviewSpot)

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
        case let .commentBand(placement): "band-\(placement.id)"
        case .commentEditor: "editor"
        }
    }
}
