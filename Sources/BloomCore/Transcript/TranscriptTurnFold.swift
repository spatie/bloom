import Foundation

/// The boundaries and duration of each agent turn.
///
/// `TranscriptFold` owns the activity groups within a turn. This scan finds the turn's boundaries
/// and duration so the work before its final answer can sit under one disclosure after the prompt.
/// It keeps completed turns when new rows arrive and rescans only the live tail.
public enum TranscriptTurnFold {
    public struct Fact: Equatable, Sendable {
        public var seq: Int
        public var kind: MessageKind
        public var parentToolUseID: String?
        public var opensTurn: Bool
        public var durationMS: Int?
        public var createdAt: Date?

        public init(
            seq: Int,
            kind: MessageKind,
            parentToolUseID: String? = nil,
            opensTurn: Bool = false,
            durationMS: Int? = nil,
            createdAt: Date? = nil
        ) {
            self.seq = seq
            self.kind = kind
            self.parentToolUseID = parentToolUseID
            self.opensTurn = opensTurn
            self.durationMS = durationMS
            self.createdAt = createdAt
        }
    }

    public struct Turn: Equatable, Sendable {
        /// Stored rows from the first work row through the result, or up to the next user message.
        public var span: Range<Int>
        public var firstSeq: Int
        public var isComplete: Bool
        public var durationMS: Int?

        public init(span: Range<Int>, firstSeq: Int, isComplete: Bool, durationMS: Int? = nil) {
            self.span = span
            self.firstSeq = firstSeq
            self.isComplete = isComplete
            self.durationMS = durationMS
        }
    }

    public struct Folds: Equatable, Sendable {
        public var all: [Turn]
        public var scannedRows: Int
        /// Just past the last result row. The unfinished tail is rescanned as it grows.
        public var resumeIndex: Int

        public static let none = Folds(all: [], scannedRows: 0, resumeIndex: 0)

        public init(all: [Turn], scannedRows: Int, resumeIndex: Int) {
            self.all = all
            self.scannedRows = scannedRows
            self.resumeIndex = resumeIndex
        }

        /// A turn interrupted by the user ends immediately before that user's row.
        public func turn(endingAt index: Int) -> Turn? {
            guard index > 0, let turn = turn(containing: index - 1),
                  turn.span.upperBound == index else { return nil }
            return turn
        }

        public func turn(containing index: Int) -> Turn? {
            var low = 0
            var high = all.count
            while low < high {
                let middle = low + (high - low) / 2
                let turn = all[middle]
                if turn.span.upperBound <= index {
                    low = middle + 1
                } else if index < turn.span.lowerBound {
                    high = middle
                } else {
                    return turn
                }
            }
            return nil
        }
    }

    /// The rows before a completed turn's final answer. The answer and anything after it stay
    /// visible, so the disclosure can sit after the prompt with the work underneath it.
    public struct Visibility: Sendable {
        public var seq: Int
        public var keepsVisible: Bool

        public init(seq: Int, keepsVisible: Bool = false) {
            self.seq = seq
            self.keepsVisible = keepsVisible
        }
    }

    public static func hiddenIndices<Rows: RandomAccessCollection>(
        turn: Turn,
        answerIndex: Int?,
        in rows: Rows,
        revealed: Set<Int>,
        drawn: Range<Int>
    ) -> Set<Int> where Rows.Element == Visibility, Rows.Index == Int {
        guard turn.isComplete,
              let answerIndex,
              turn.span.lowerBound < answerIndex,
              answerIndex < turn.span.upperBound,
              drawn.lowerBound <= turn.span.lowerBound,
              turn.span.upperBound <= drawn.upperBound
        else { return [] }

        let work = turn.span.lowerBound..<answerIndex
        // A search result or an opened tool row needs its context. Keep the whole turn open until
        // the reader leaves it rather than hiding the target behind a control above the viewport.
        guard !work.contains(where: { revealed.contains(rows[$0].seq) }) else { return [] }
        return Set(work.filter { !rows[$0].keepsVisible })
    }

    /// The activity groups that have rows to hide in the current drawing window.
    public static func hiddenActivity(
        work: TranscriptFold.Folds,
        revealed: Set<Int>,
        drawn: Range<Int>
    ) -> [Int: Set<Int>] {
        var hiddenByWork: [Int: Set<Int>] = [:]
        for group in work.all where drawn.contains(group.span.lowerBound) {
            let hidden = TranscriptFold.hiddenIndices(group, revealed: revealed, drawn: drawn)
            guard !hidden.isEmpty else { continue }
            hiddenByWork[group.firstSeq] = hidden
        }
        return hiddenByWork
    }

    public static func folds<Facts: RandomAccessCollection>(
        in facts: Facts,
        extending previous: Folds = .none
    ) -> Folds where Facts.Element == Fact, Facts.Index == Int {
        let count = facts.count
        var start = previous.resumeIndex
        var found: [Turn]
        if count < previous.scannedRows || start > count {
            start = 0
            found = []
        } else {
            found = previous.all.filter { $0.span.upperBound <= start }
        }

        var turnStart: Int?
        var turnStartedAt: Date?
        var acceptsResultDuration = true
        var resume = start

        func elapsed(until end: Date?) -> Int? {
            turnStartedAt.flatMap { started in
                end.map { max(0, Int($0.timeIntervalSince(started) * 1_000)) }
            }
        }

        func appendTurn(endingAt end: Int, isComplete: Bool, durationMS: Int?) {
            guard let turnStart, turnStart < end else { return }
            let first = facts[facts.index(facts.startIndex, offsetBy: turnStart)]
            found.append(Turn(
                span: turnStart..<end,
                firstSeq: first.seq,
                isComplete: isComplete,
                durationMS: durationMS
            ))
        }

        for offset in start..<count {
            let fact = facts[facts.index(facts.startIndex, offsetBy: offset)]
            guard fact.parentToolUseID == nil else { continue }

            if fact.kind == .user || fact.kind == .crew || fact.opensTurn {
                if turnStart != nil {
                    // A background wake starts new work without ending the previous turn.
                    if !fact.opensTurn {
                        appendTurn(endingAt: offset, isComplete: true,
                                   durationMS: elapsed(until: fact.createdAt))
                    }
                    acceptsResultDuration = false
                } else {
                    acceptsResultDuration = true
                }
                turnStartedAt = fact.createdAt
                turnStart = offset + 1
                continue
            }

            if fact.kind == .result {
                let reported = acceptsResultDuration
                    ? fact.durationMS.flatMap { $0 > 0 ? $0 : nil }
                    : nil
                appendTurn(endingAt: offset + 1, isComplete: true,
                           durationMS: reported ?? elapsed(until: fact.createdAt))
                turnStart = nil
                turnStartedAt = nil
                acceptsResultDuration = true
                resume = offset + 1
            }
        }

        if turnStart != nil {
            appendTurn(endingAt: count, isComplete: false, durationMS: nil)
        }

        return Folds(all: found, scannedRows: count, resumeIndex: min(resume, count))
    }

    public static func label(milliseconds: Int) -> String {
        let duration = TurnDuration.wholeSeconds(milliseconds)
        return duration == "0s" ? "Worked for a while" : "Worked for \(duration)"
    }
}
