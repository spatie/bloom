import Foundation

/// Which turn the stop on a stopped chat belongs to.
///
/// A `SessionState` says what the chat is doing now, not what each of its turns did, so a stopped
/// chat knows it was stopped and does not know where. The answer is always the same one, though:
/// the state moves off `cancelled` the moment another turn starts, so the stop can only be about
/// the last one, and the row that closed it is the last `result` in the transcript.
///
/// The one case that is not that, and the reason this is a function rather than `rows.last`: a
/// stop can leave no result row at all, when the CLI is killed before it says anything. Then the
/// last result in the list closed an **earlier** turn, which finished perfectly well, and marking
/// it stopped would put a sentence about a button under a turn nobody touched. A `user` row below
/// the last result is what says so, because it is the start of the turn that has no result yet.
public enum StoppedTurn {
    /// The row that closed the stopped turn, or nil when the stop left none.
    ///
    /// Generic over the collection so a caller can hand it `rows.lazy.map(\.kind)` and allocate
    /// nothing: this is asked on every pass over a transcript that can hold thousands of rows,
    /// and the walk itself reads two or three of them from the end.
    public static func closingRow<Rows: RandomAccessCollection>(
        in kinds: Rows
    ) -> Rows.Index? where Rows.Element == MessageKind {
        for index in kinds.indices.reversed() {
            switch kinds[index] {
            case .result: return index
            case .user: return nil
            default: continue
            }
        }
        return nil
    }
}
