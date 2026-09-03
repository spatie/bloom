import Foundation
import Testing
@testable import BloomCore

/// What a turn's working is, where it ends, and what may be hidden while the turn is still running.
///
/// The decision is here rather than in `TranscriptListView` for the reason the three target split
/// exists. It is also the reason the fold is worth having at all: a turn that draws as two entries
/// is thirty-eight rows that are never keyed, never measured and never built, and none of that
/// could be checked from inside a view.
///
/// **Half of this suite is about one property: what a fold hides only ever grows.** Folding while
/// the turn works means hiding a row whose result has not come back, and a result can say the call
/// failed. Every rule that could react to that by revealing a row would be an unfold under a reader
/// who is watching the turn. `monotone` below is that property written down against a scripted turn.
@Suite("Folding a turn's working")
struct TranscriptFoldTests {
    // MARK: Fixtures

    private func tool(_ seq: Int, failed: Bool = false, settled: Bool = true) -> TranscriptFold.Fact {
        TranscriptFold.Fact(seq: seq, kind: .toolUse, failed: failed, settled: settled)
    }

    private func prose(_ seq: Int) -> TranscriptFold.Fact {
        TranscriptFold.Fact(seq: seq, kind: .assistantText)
    }

    private func thinking(_ seq: Int) -> TranscriptFold.Fact {
        TranscriptFold.Fact(seq: seq, kind: .thinking)
    }

    private func notice(_ seq: Int) -> TranscriptFold.Fact {
        TranscriptFold.Fact(seq: seq, kind: .notice)
    }

    /// A permission question. Undecided is a row that can still change, which is the whole of why
    /// it is never buried.
    private func ask(_ seq: Int, decided: Bool = true) -> TranscriptFold.Fact {
        TranscriptFold.Fact(seq: seq, kind: .permissionAsk, settled: decided)
    }

    private func failure(_ seq: Int) -> TranscriptFold.Fact {
        TranscriptFold.Fact(seq: seq, kind: .error)
    }

    /// The rows that make up sixty per cent of a real session and draw nothing at all.
    private func quiet(_ seq: Int) -> TranscriptFold.Fact {
        TranscriptFold.Fact(seq: seq, kind: .system, drawsNothing: true)
    }

    private func user(_ seq: Int) -> TranscriptFold.Fact {
        TranscriptFold.Fact(seq: seq, kind: .user)
    }

    private func footer(_ seq: Int) -> TranscriptFold.Fact {
        TranscriptFold.Fact(seq: seq, kind: .result)
    }

    private let everything = 0..<1_000

    private func hides(_ work: TranscriptFold.Work, revealed: Set<Int> = []) -> Int {
        TranscriptFold.hides(work, revealed: revealed, drawn: everything)
    }

    private func only(_ facts: [TranscriptFold.Fact]) throws -> TranscriptFold.Work {
        let folds = TranscriptFold.folds(in: facts)
        #expect(folds.all.count == 1)
        return try #require(folds.all.first)
    }

    // MARK: What a turn's working is

    /// Black prose is the useful account of what the agent is doing. It stays in the transcript
    /// and divides the grey activity before and after it into separate groups.
    @Test("assistant prose remains visible between consecutive activity groups")
    func proseSeparatesActivity() {
        let facts = [user(0)]
            + (1..<4).map { tool($0) } + [prose(4)]
            + (5..<8).map { tool($0) } + [notice(8)]
            + (9..<12).map { tool($0) } + [prose(12), footer(13)]
        let folds = TranscriptFold.folds(in: facts)
        #expect(folds.all.map(\.span) == [1..<4, 5..<12])
        #expect(folds.all.map(\.rows.count) == [3, 7])
        #expect(folds.all.map(\.hasAnswer) == [true, true])
        #expect(folds.all.map { hides($0) } == [3, 7])
    }

    @Test("thinking, a subagent's rows and the stream events between them all fold")
    func everythingBetweenFolds() throws {
        let facts = [user(0), thinking(1), quiet(2), tool(3), quiet(4), tool(5), prose(6), footer(7)]
        let work = try only(facts)
        #expect(work.rows.map(\.seq) == [1, 3, 5])
        // The quiet rows are inside the span and are not counted, because they draw nothing.
        #expect(work.span == 1..<6)
        #expect(hides(work) == 3)
    }

    @Test("user messages, assistant prose and turn footers are boundaries")
    func theBoundaries() {
        let facts = [user(0)]
            + (1..<5).map { tool($0) } + [prose(5), footer(6), user(7)]
            + (8..<12).map { tool($0) } + [prose(12)]
        let folds = TranscriptFold.folds(in: facts)
        #expect(folds.all.count == 2)
        #expect(folds.all.map(\.span) == [1..<5, 8..<12])
    }

    // MARK: Prose remains visible

    @Test("two prose blocks divide the activity around them")
    func twoProseBlocks() {
        let facts = [user(0), tool(1), tool(2), prose(3), tool(4), tool(5), prose(6), footer(7)]
        let folds = TranscriptFold.folds(in: facts)
        #expect(folds.all.map { $0.rows.map(\.seq) } == [[1, 2], [4, 5]])
        #expect(folds.all.map(\.hasAnswer) == [true, true])
    }

    /// A turn that ends on a settled tool call has no answer, so all of it is working. The view
    /// uses the newest hidden row as the fold's visible label.
    @Test("a turn that ends on settled work includes its newest row in the fold")
    func noAnswer() throws {
        let facts = [user(0)] + (1..<8).map { tool($0) } + [footer(8)]
        let work = try only(facts)
        #expect(!work.hasAnswer)
        #expect(hides(work) == 7)
        #expect(work.rows[hides(work) - 1].seq == 7)
    }

    @Test("prose before more work stays outside both activity groups")
    func proseThenWork() {
        let facts = [user(0), tool(1), tool(2), prose(3), tool(4), tool(5), tool(6), footer(7)]
        let folds = TranscriptFold.folds(in: facts)
        #expect(folds.all.map { $0.rows.map(\.seq) } == [[1, 2], [4, 5, 6]])
        #expect(folds.all.map(\.hasAnswer) == [true, false])
    }

    /// A rate limit notice landing after the answer is not working, so it stays with the answer
    /// rather than dragging it into the fold. The walk back stops at rows a reader would call work.
    @Test("a notice after the answer keeps the answer out of the fold")
    func noticeAfterTheAnswer() throws {
        let facts = [user(0)] + (1..<6).map { tool($0) } + [prose(6), notice(7), footer(8)]
        let work = try only(facts)
        #expect(work.hasAnswer)
        #expect(work.span == 1..<6)
    }

    /// A turn with no prose in its tail at all has no answer however quiet the tail is.
    @Test("a tail with no prose in it is not an answer")
    func aTailWithoutProse() throws {
        let facts = [user(0)] + (1..<7).map { tool($0) } + [quiet(7), footer(8)]
        let work = try only(facts)
        #expect(!work.hasAnswer)
    }

    // MARK: The thresholds

    @Test("a working shorter than three rows hides nothing")
    func theThreshold() {
        /// A turn of `count` calls, answered, so the whole working is foldable.
        func turn(of count: Int) -> [TranscriptFold.Fact] {
            [user(0)] + (1...count).map { tool($0) } + [prose(count + 1), footer(count + 2)]
        }
        #expect(TranscriptFold.folds(in: turn(of: 1)).all.isEmpty)
        #expect(TranscriptFold.folds(in: turn(of: 2)).all.map { hides($0) } == [0])
        #expect(TranscriptFold.folds(in: turn(of: 3)).all.map { hides($0) } == [3])
        #expect(TranscriptFold.folds(in: turn(of: 9)).all.map { hides($0) } == [9])
    }

    /// **The gap between `leastWork` and `leastHidden` is what keeps folding off `reloadData`.**
    /// The fold's line is an entry, and an entry that appeared on the same pass that rows left the
    /// list would be two edits `TranscriptEntryChange` can only call `.rebuilt`.
    @Test("a working gets its line long before it can fold")
    func theLineArrivesEarly() {
        #expect(TranscriptFold.leastWork < TranscriptFold.leastHidden)
        let two = [user(0), tool(1), tool(2)]
        #expect(TranscriptFold.folds(in: two).all.count == 1)
        #expect(TranscriptFold.folds(in: two).all.map { hides($0) } == [0])
        // One row is not a working at all: it can never fold whatever the threshold, and a single
        // call between two paragraphs is the commonest shape in a transcript.
        #expect(TranscriptFold.folds(in: [user(0), tool(1), prose(2)]).all.isEmpty)
    }

    // MARK: What is never hidden

    /// **Rule 1.** A row whose result has not come back can still change what it says, so it is
    /// drawn until it has. A message's parallel calls arrive with no results at all.
    @Test("a row whose result has not arrived is never hidden")
    func unsettledRowsAreNeverHidden() throws {
        let parallel = [user(0)] + (1..<7).map { tool($0, settled: false) }
        #expect(hides(try only(parallel)) == 0)

        let partly = [user(0)] + (1..<7).map { tool($0, settled: $0 < 5) }
        let work = try only(partly)
        #expect(work.ready == 4)
        #expect(hides(work) == 4)
    }

    /// The prefix stops at the first row still waiting, so a later result cannot reach over one
    /// that has not come back.
    @Test("a settled row behind an unsettled one is still not hidden")
    func thePrefixHasNoGaps() throws {
        let facts = [user(0), tool(1), tool(2), tool(3, settled: false), tool(4), tool(5), tool(6)]
        let work = try only(facts)
        #expect(work.ready == 2)
        #expect(hides(work) == 0)
    }

    /// A failed command remains visible and divides the surrounding activity into two compact
    /// groups. It must not expose every ordinary action that follows it.
    @Test("a failed call separates consecutive activity groups")
    func aFailureSeparatesGroups() {
        let facts = [user(0)] + (1..<10).map { tool($0, failed: $0 == 5) }
        let folds = TranscriptFold.folds(in: facts)
        #expect(folds.all.count == 2)
        #expect(folds.all.map(\.rows.count) == [4, 4])
        #expect(folds.all.map { hides($0) } == [4, 4])
        #expect(folds.index(containing: 5) == nil)
    }

    @Test("many ordinary rows after consecutive failures form another group")
    func activityAfterFailuresFoldsAgain() {
        let facts = [user(0)]
            + (1..<41).map { tool($0) }
            + [tool(41, failed: true), tool(42, failed: true)]
            + (43..<63).map { tool($0) }
        let folds = TranscriptFold.folds(in: facts)
        #expect(folds.all.map(\.rows.count) == [40, 20])
        #expect(folds.all.map { hides($0) } == [40, 20])
        #expect(folds.index(containing: 41) == nil)
        #expect(folds.index(containing: 42) == nil)
    }

    /// An error row is the turn itself failing, and it is treated the same way.
    @Test("an error row stops the fold")
    func anErrorStopsTheFold() throws {
        let facts = [user(0), tool(1), tool(2), tool(3), tool(4), failure(5), tool(6)]
        #expect(hides(try only(facts)) == 4)
    }

    /// **Rule 3, and the fault this file could least afford.** A question the turn is stopped on,
    /// buried behind a line, is a reader waiting for an agent that is waiting for them.
    @Test("a question nobody has answered is never hidden")
    func anUndecidedAskIsNeverHidden() throws {
        let waiting = [user(0), tool(1), tool(2), tool(3), tool(4), ask(5, decided: false), tool(6)]
        #expect(hides(try only(waiting)) == 4)
        // Answered, it is history and folds away with everything else through the newest row.
        let decided = [user(0), tool(1), tool(2), tool(3), tool(4), ask(5), tool(6)]
        #expect(hides(try only(decided)) == 6)
    }

    /// **Rule 4.** A tool result the reader opened is a row they are reading. Refusing to fold at
    /// all would unfold a turn that had already folded, so the prefix stops there instead.
    @Test("an opened row cuts the fold short rather than unfolding it")
    func anOpenedRowCapsThePrefix() throws {
        let work = try only([user(0)] + (1..<11).map { tool($0) })
        #expect(hides(work) == 10)
        #expect(hides(work, revealed: [5]) == 4)
        // A row further along cuts it no further than it already was.
        #expect(hides(work, revealed: [7, 5]) == 4)
    }

    /// **The one that is worse than cosmetic.** A scroll can only find a row the table is DRAWING,
    /// so a search hit or an unread mark inside a fold is not a row somewhere off screen, it is a
    /// scroll that lands nowhere at all.
    @Test("a row something is aiming at is never hidden")
    func aSearchHitIsNeverHidden() throws {
        let work = try only([user(0)] + (1..<11).map { tool($0) })
        for seq in 1..<10 {
            #expect(hides(work, revealed: [seq]) <= seq - 1, "row \(seq) must still be drawn")
        }
        #expect(hides(work, revealed: [99]) == 10)
    }

    /// A failure that has not settled by the caller's reckoning is still settled here. A result
    /// writes `is_error` and the payload in one go, and a caller that let the two come apart would
    /// let a hidden row turn into a failure and force an unfold.
    @Test("a failure counts as settled whatever the caller said")
    func aFailureIsSettled() throws {
        let facts = [user(0)] + (1..<7).map { tool($0, failed: $0 == 6, settled: $0 != 6) }
        let work = try only(facts)
        #expect(work.ready == 5)
        #expect(hides(work) == 5)
    }

    // MARK: The window

    /// A window that stops inside a turn's working cannot fold it: the rows it would leave are rows
    /// the table is not drawing.
    @Test("a working that runs past the drawn window does not fold")
    func aWorkingOutsideTheWindowDoesNotFold() throws {
        let work = try only([user(0)] + (1..<7).map { tool($0) })
        #expect(TranscriptFold.hides(work, revealed: [], drawn: 0..<7) == 6)
        #expect(TranscriptFold.hides(work, revealed: [], drawn: 0..<6) == 0)
    }

    /// Only the window's end is asked about. Its start moves down as a reader scrolls back, and
    /// what is hidden is an absolute range of rows, so a growth upwards puts rows in without taking
    /// any out.
    @Test("the window's start does not move what is hidden")
    func growingUpwardsTakesNothingOut() throws {
        let work = try only([user(0)] + (1..<7).map { tool($0) })
        #expect(TranscriptFold.hides(work, revealed: [], drawn: 4..<20) == 6)
        #expect(TranscriptFold.hides(work, revealed: [], drawn: 0..<20) == 6)
    }

    // MARK: Nothing unfolds

    /// **The property the whole design is arranged around, against a scripted turn.**
    ///
    /// Eleven rows arrive one at a time, each one's result landing as the next is issued, with the
    /// fifth coming back a failure and the reader having opened the seventh. At no point may the
    /// number of hidden rows go down, because a fold that reveals a row it had hidden is a
    /// transcript rearranging itself under somebody who is reading it.
    @Test("what a fold hides only ever grows")
    func monotone() {
        var facts = [user(0)]
        var folds = TranscriptFold.Folds.none
        var seen: [Int: Int] = [:]
        let revealed: Set<Int> = [7]

        for seq in 1..<12 {
            // The result of the row before this one comes back as this one is issued, which is the
            // order the CLI writes them in. The fifth comes back a failure.
            for at in facts.indices where facts[at].kind == .toolUse && !facts[at].settled {
                facts[at].settled = true
                facts[at].failed = facts[at].seq == 5
            }
            facts.append(tool(seq, settled: false))
            folds = TranscriptFold.folds(in: facts, extending: folds)
            for work in folds.all {
                let now = hides(work, revealed: revealed)
                #expect(now >= (seen[work.firstSeq] ?? 0), "row \(seq) unfolded \(work.firstSeq)")
                seen[work.firstSeq] = now
            }
        }
        // And the turn ends: the last result comes back, the answer lands, then the footer.
        for at in facts.indices where facts[at].kind == .toolUse { facts[at].settled = true }
        facts.append(prose(99))
        folds = TranscriptFold.folds(in: facts, extending: folds)
        for work in folds.all {
            #expect(hides(work, revealed: revealed) >= (seen[work.firstSeq] ?? 0))
        }
    }

    // MARK: The words

    /// Expanded folds spell out the count. Collapsed folds show it in their leading circle.
    @Test("the expanded line names what is hidden and how many")
    func theLabel() {
        #expect(TranscriptFold.label(hiding: 14, showsMore: false) == "14 actions")
        #expect(TranscriptFold.label(hiding: 11, showsMore: true) == "11 actions")
    }

    /// Two wordings for two different claims. While a turn is working there is a row of it still on
    /// screen, so the hidden ones are the ones above it; once the answer has landed the whole of
    /// the working is behind the line and there is no "earlier" left for the word to mean.
    @Test("the singular is there for whoever lowers the threshold")
    func theLabelHasASingular() {
        #expect(TranscriptFold.label(hiding: 1, showsMore: true) == "1 action")
        #expect(TranscriptFold.label(hiding: 1, showsMore: false) == "1 action")
    }

    @Test("an open live turn folds back when new work reaches the live end")
    func refoldingLiveWork() throws {
        let live = try only([user(0)] + (1..<7).map { tool($0) })
        let laterLive = TranscriptFold.Work(
            span: 20..<24,
            rows: (20..<24).map { TranscriptFold.Row(index: $0, seq: $0) },
            ready: 4,
            hasAnswer: false
        )
        let historical = TranscriptFold.Work(
            span: 10..<14,
            rows: (10..<14).map { TranscriptFold.Row(index: $0, seq: $0) },
            ready: 4,
            hasAnswer: true
        )
        let folds = TranscriptFold.Folds(
            all: [historical, live, laterLive], scannedRows: 24, resumeIndex: 1
        )

        #expect(
            TranscriptFold.refoldedAtLiveEnd(
                [historical.firstSeq, live.firstSeq, laterLive.firstSeq], in: folds
            ) == [historical.firstSeq]
        )
        #expect(
            TranscriptFold.refoldedAtLiveEnd([historical.firstSeq], in: folds)
                == [historical.firstSeq]
        )
    }

    // MARK: Finding a fold by row

    @Test("a row index finds the working it is in, and only that one")
    func lookupByIndex() {
        let facts = [user(0)] + (1..<5).map { tool($0) } + [prose(5), footer(6), user(7)]
            + (8..<12).map { tool($0) } + [prose(12)]
        let folds = TranscriptFold.folds(in: facts)
        #expect(folds.index(containing: 0) == nil)
        #expect(folds.fold(containing: 1)?.firstSeq == 1)
        #expect(folds.fold(containing: 4)?.firstSeq == 1)
        #expect(folds.index(containing: 5) == nil)
        #expect(folds.fold(containing: 8)?.firstSeq == 8)
        #expect(folds.fold(containing: 11)?.firstSeq == 8)
        #expect(folds.index(containing: 12) == nil)
        #expect(folds.index(containing: 99) == nil)
    }

    // MARK: Extending a scan

    /// Rows are appended and never reordered, so a scan only ever has to redo the last turn.
    @Test("extending a scan gives the same answer as scanning from nothing")
    func extendingMatchesAFullScan() {
        var facts: [TranscriptFold.Fact] = []
        var extended = TranscriptFold.Folds.none
        let script: [TranscriptFold.Fact] = [
            user(0), tool(1), quiet(2), thinking(3), tool(4), prose(5), tool(6), notice(7),
            tool(8), tool(9), prose(10), footer(11),
            user(12), tool(13), tool(14, failed: true), ask(15, decided: false), tool(16), prose(17),
        ]
        for fact in script {
            facts.append(fact)
            extended = TranscriptFold.folds(in: facts, extending: extended)
            let whole = TranscriptFold.folds(in: facts)
            #expect(extended.all == whole.all, "after \(facts.count) rows")
            #expect(extended.resumeIndex == whole.resumeIndex, "after \(facts.count) rows")
            #expect(extended.scannedRows == whole.scannedRows, "after \(facts.count) rows")
        }
    }

    /// A session being replaced rather than grown, which is what a pane switching conversations
    /// hands this.
    @Test("a shorter list than last time is scanned from the beginning")
    func aShorterListRescans() {
        let long = TranscriptFold.folds(in: [user(0)] + (1..<20).map { tool($0) })
        let short = [user(0), tool(1), tool(2), tool(3), prose(4)]
        let rescanned = TranscriptFold.folds(in: short, extending: long)
        #expect(rescanned.all == TranscriptFold.folds(in: short).all)
        #expect(rescanned.scannedRows == 5)
    }

    /// **A rescan resumes past the last row that ENDED a turn, not past the last fold.** A turn
    /// that is still running has a working whose answer is provisional and whose settled prefix is
    /// about to grow, so it is rescanned in full every time a row lands.
    @Test("a rescan resumes past the last boundary")
    func resumeIsPastTheLastBoundary() {
        let facts = [user(0), tool(1), tool(2), prose(3), footer(4), user(5), tool(6), tool(7)]
        #expect(TranscriptFold.folds(in: facts).resumeIndex == 6)
    }
}
