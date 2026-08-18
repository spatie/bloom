import BloomCore

/// A flattened render list. Building it once per state change, rather than deriving it inside
/// `body`, keeps a fifty thousand line diff from walking its own hunks on every layout pass.
enum DiffRow: Identifiable {
    case header(id: Int, text: String)
    case runExpander(id: Int, runID: Int, hidden: Int)
    case gapExpander(id: Int, gapID: Int, hidden: Int)
    case line(id: Int, line: DiffLine)
    case pair(id: Int, row: SideBySideRow)

    var id: Int {
        switch self {
        case let .header(id, _): id
        case let .runExpander(id, _, _): id
        case let .gapExpander(id, _, _): id
        case let .line(id, _): id
        case let .pair(id, _): id
        }
    }
}
