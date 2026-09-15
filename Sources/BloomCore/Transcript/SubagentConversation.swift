import Foundation

/// A subagent's conversation laid out the way the chat lays out a turn: runs of working folded
/// into one "N actions" line, prose left standing between them.
///
/// **The owner opened a subagent and found a pane that looked nothing like the chat beside it.**
/// Every tool call was a row of its own, flush left and the full width of the pane, and every
/// thinking block was another, so a four minute subagent was a column of sixty grey lines with its
/// answer somewhere at the foot. The rows were already the transcript's own rows; what was missing
/// was the transcript's fold, which the pane had deliberately left out on the grounds that this is
/// the view somebody opens BECAUSE the chat folded the work away. Reading it the way the chat reads
/// was the better answer: the fold opens with one click, and the answer is what a person opens a
/// subagent to find.
///
/// **So this is `TranscriptFold` and not a second rule.** The facts go through
/// `TranscriptFold.folds(in:)` and `TranscriptFold.hiddenIndices`, which decide what a run is and
/// what may be hidden for every conversation in the window; what is here is only the emitting that
/// `TranscriptListView` does inline for the chat, lifted out so it can be tested, and two
/// differences that belong to this pane alone:
///
/// 1. **Every row is top level.** A line read off the parent's live stream carries the
///    `parent_tool_use_id` of the Task call that started the subagent, which is what indents it
///    in the chat. Here the subagent IS the conversation, so the id is the same on every row and
///    would only draw every fold line nested behind a rule with nothing above it to hang from.
/// 2. **The identity a fold is kept open under is whatever the caller put in `seq`.** The pane
///    re-reads once a second and hands over from the live stream to the CLI's file when the
///    subagent ends, so positions move under it. The pane passes each row's payload derived id
///    (`SubagentTranscript.rowID`), which does not.
public enum SubagentConversation {
    /// One thing the pane draws, in order.
    public enum Entry: Equatable, Sendable {
        /// The line standing for a run of working.
        ///
        /// - `firstSeq`: the run's identity, which is the `seq` of its first row. What the reader
        ///   opening it is recorded against.
        /// - `hiding`: the count the line shows. What it hides while folded, and the whole run
        ///   while open, which is what `TranscriptListView` shows for the chat.
        /// - `showsMore`: folded, with some of the run still standing below the line.
        case fold(firstSeq: Int, hiding: Int, showsMore: Bool, isFolded: Bool)
        /// A row of the conversation, by its index in the facts handed in.
        case row(index: Int, seq: Int)

        /// Stable across a re-read for as long as the `seq` values are.
        public var id: Identity {
            switch self {
            case .fold(let firstSeq, _, _, _): .fold(firstSeq)
            case .row(_, let seq): .row(seq)
            }
        }
    }

    /// Two namespaces, because a fold is named after its first row and would otherwise share that
    /// row's identity.
    public enum Identity: Hashable, Sendable {
        case fold(Int)
        case row(Int)
    }

    /// - Parameters:
    ///   - facts: one per row, in order. `seq` is the row's stable identity rather than a position.
    ///   - unfolded: the runs the reader has opened, by `firstSeq`.
    ///   - revealed: the rows the reader has opened, by `seq`. An opened tool call caps its run
    ///     exactly as it does in the chat, so a result somebody is reading is never folded away
    ///     under them when the run around it settles.
    public static func entries(
        facts: [TranscriptFold.Fact], unfolded: Set<Int>, revealed: Set<Int>
    ) -> [Entry] {
        let flat = facts.map { fact in
            var own = fact
            own.parentToolUseID = nil
            return own
        }
        let folds = TranscriptFold.folds(in: flat)
        let drawn = 0..<flat.count

        var out: [Entry] = []
        var foldSeq: Int?
        var hidden: Set<Int> = []
        for index in flat.indices {
            if let at = folds.index(containing: index) {
                let work = folds.all[at]
                if work.firstSeq != foldSeq {
                    foldSeq = work.firstSeq
                    let would = TranscriptFold.hiddenIndices(work, revealed: revealed, drawn: drawn)
                    hidden = unfolded.contains(work.firstSeq) ? [] : would
                    let isFolded = !hidden.isEmpty
                    // A run with nothing to hide gets no line, for the chat's reason: a control
                    // that answers nothing when it is pressed is worse than no control.
                    if !would.isEmpty {
                        out.append(.fold(
                            firstSeq: work.firstSeq,
                            hiding: isFolded ? would.count : work.rows.count,
                            showsMore: isFolded && would.count < work.rows.count,
                            isFolded: isFolded
                        ))
                    }
                }
                if hidden.contains(index) { continue }
            }
            guard !flat[index].drawsNothing else { continue }
            out.append(.row(index: index, seq: flat[index].seq))
        }
        return out
    }
}
