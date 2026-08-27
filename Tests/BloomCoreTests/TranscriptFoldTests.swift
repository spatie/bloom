import Foundation
import Testing
@testable import BloomCore

/// What forms a run of tool calls, what breaks one, and when one refuses to fold.
///
/// The decision is here rather than in `TranscriptListView` for the reason the three target split
/// exists. It is also the reason the fold is worth having at all: a run that draws as one entry is
/// a run whose other rows are never keyed, never measured and never built, and none of that could
/// be checked from inside a view.
@Suite("Folding a run of tool calls")
struct TranscriptFoldTests {
    // MARK: Fixtures

    private func tool(_ seq: Int, failed: Bool = false, nested: Bool = false) -> TranscriptFold.Fact {
        TranscriptFold.Fact(
            seq: seq, kind: .toolUse, failed: failed, nested: nested, drawsNothing: false
        )
    }

    /// The rows that make up sixty per cent of a real session and draw nothing at all.
    private func quiet(_ seq: Int) -> TranscriptFold.Fact {
        TranscriptFold.Fact(
            seq: seq, kind: .system, failed: false, nested: false, drawsNothing: true
        )
    }

    private func prose(_ seq: Int) -> TranscriptFold.Fact {
        TranscriptFold.Fact(
            seq: seq, kind: .assistantText, failed: false, nested: false, drawsNothing: false
        )
    }

    private func row(_ seq: Int, _ kind: MessageKind) -> TranscriptFold.Fact {
        TranscriptFold.Fact(seq: seq, kind: kind, failed: false, nested: false, drawsNothing: false)
    }

    /// Four calls and the prose that closes them, which is the shortest run that folds.
    private var closedRun: [TranscriptFold.Fact] {
        [tool(0), tool(1), tool(2), tool(3), prose(4)]
    }

    // MARK: What forms a run

    @Test("consecutive tool calls, closed by prose, are one run")
    func aClosedRunIsFound() throws {
        let runs = TranscriptFold.runs(in: closedRun)
        #expect(runs.runs.count == 1)
        let run = try #require(runs.runs.first)
        #expect(run.rows == 0..<4)
        #expect(run.firstSeq == 0)
        #expect(run.lastDrawnIndex == 3)
        #expect(run.hiddenCount == 3)
        #expect(run.canFold)
    }

    /// **The owner's own screenshot**: `Read`, `Bash`, `Bash`, `Edit`, `Bash`, `Bash`, `Bash`, then
    /// prose. The kinds of tool are never consulted, so the `Edit` in the middle joins rather than
    /// cutting the run into a three and a three with a stray row between them.
    @Test("a mixed run of reads, edits and commands is one run")
    func aMixedRunJoins() {
        let facts = (0..<7).map { tool($0) } + [prose(7)]
        let runs = TranscriptFold.runs(in: facts)
        #expect(runs.runs.count == 1)
        #expect(runs.runs.first?.hiddenCount == 6)
    }

    /// The rule that decides whether there are any runs at all. Three to five `system` rows sit
    /// between every pair of tool calls in a real session, and letting one break a run would mean
    /// no run in any transcript ever reached four.
    @Test("rows that draw nothing sit inside a run without breaking it or being counted")
    func quietRowsAreTransparent() throws {
        let facts = [
            tool(0), quiet(1), quiet(2), tool(3), quiet(4), tool(5), tool(6), prose(7),
        ]
        let runs = TranscriptFold.runs(in: facts)
        #expect(runs.runs.count == 1)
        let run = try #require(runs.runs.first)
        // The run spans the quiet rows it swallowed, and counts only the four calls.
        #expect(run.rows == 0..<7)
        #expect(run.hiddenCount == 3)
        #expect(run.lastDrawnIndex == 6)
    }

    /// Trailing quiet rows are left outside. A run ends at the last thing it draws, and stretching
    /// it over rows the next turn's prose might follow would make the fold's span a guess.
    @Test("a run ends at its last call, not at the quiet rows after it")
    func trailingQuietRowsStayOutside() {
        let runs = TranscriptFold.runs(in: [
            tool(0), tool(1), tool(2), tool(3), quiet(4), quiet(5), prose(6),
        ])
        #expect(runs.runs.first?.rows == 0..<4)
    }

    @Test("everything the reader would have read breaks a run")
    func drawingRowsBreakARun() {
        let breakers: [MessageKind] = [
            .assistantText, .thinking, .user, .permissionAsk, .error, .notice, .result, .toolResult,
        ]
        for kind in breakers {
            let runs = TranscriptFold.runs(in: [
                tool(0), tool(1), row(2, kind), tool(3), tool(4), prose(5),
            ])
            #expect(runs.runs.isEmpty, "\(kind) should have cut the run into two shorter ones")
        }
    }

    /// A session start is a `system` row that DOES draw, so it breaks a run like anything else the
    /// reader can see. `TranscriptRowInk` is what tells the two apart, and this is the half of it
    /// that matters here.
    @Test("a system row that draws breaks a run, and one that does not never did")
    func aDrawingSystemRowBreaksARun() {
        let drawing = TranscriptFold.Fact(
            seq: 2, kind: .system, failed: false, nested: false, drawsNothing: false
        )
        let runs = TranscriptFold.runs(in: [tool(0), tool(1), drawing, tool(3), tool(4), prose(5)])
        #expect(runs.runs.isEmpty)
    }

    /// A subagent's rows are drawn indented under the call that started them. Swallowing two indent
    /// levels into one line would be a fold that lies about where its calls happened.
    @Test("a change of indent starts a new run rather than lengthening one")
    func nestingBreaksARun() {
        let facts = [
            tool(0), tool(1), tool(2), tool(3),
            tool(4, nested: true), tool(5, nested: true), tool(6, nested: true),
            tool(7, nested: true), prose(8),
        ]
        let runs = TranscriptFold.runs(in: facts)
        #expect(runs.runs.count == 2)
        #expect(runs.runs.first?.rows == 0..<4)
        #expect(runs.runs.last?.rows == 4..<8)
    }

    // MARK: The threshold

    /// Three calls fold to a line and a row, which is two lines where three were: one line bought
    /// for a control and a decision. Four halves the run, which is the point at which it pays.
    @Test("a run shorter than four is not a run")
    func shortRunsAreNotFolded() {
        for length in 0..<TranscriptFold.leastRun {
            let facts = (0..<length).map { tool($0) } + [prose(length)]
            #expect(TranscriptFold.runs(in: facts).runs.isEmpty, "\(length) calls should not fold")
        }
        let four = (0..<4).map { tool($0) } + [prose(4)]
        #expect(TranscriptFold.runs(in: four).runs.count == 1)
    }

    // MARK: When a run refuses to fold

    /// **Collapse on completion, not on arrival.** The rows arriving during a turn are what the
    /// reader is watching, and a run at the live end is still growing.
    @Test("a run still growing at the end of the rows does not fold")
    func anOpenRunDoesNotFold() {
        let runs = TranscriptFold.runs(in: (0..<7).map { tool($0) })
        #expect(runs.runs.count == 1)
        #expect(runs.runs.first?.canFold == false)
    }

    /// It is emitted all the same, and that is the whole reason folding costs no reload: the
    /// fold's own entry has to already be in the list on the pass that removes rows from it.
    @Test("an open run is still emitted, so its line is in the list before it folds")
    func anOpenRunIsStillEmitted() {
        #expect(TranscriptFold.runs(in: (0..<7).map { tool($0) }).runs.count == 1)
    }

    /// Stolen from VS Code's `chat.tools.autoExpandFailures`, which is on by default. A failed
    /// command is the one you are scrolling to find.
    @Test("a run holding a failure never folds")
    func aFailureStopsAFold() {
        let facts = [tool(0), tool(1), tool(2, failed: true), tool(3), tool(4), prose(5)]
        let runs = TranscriptFold.runs(in: facts)
        #expect(runs.runs.count == 1)
        #expect(runs.runs.first?.canFold == false)
    }

    /// And it does not cut the run in two. A result marking a call failed arrives after the call,
    /// so a rule that re-cut the runs would move a fold's identity out from under the table on the
    /// pass the result landed.
    @Test("a failure stops the fold rather than splitting the run")
    func aFailureDoesNotSplitTheRun() {
        let facts = [tool(0), tool(1), tool(2, failed: true), tool(3), tool(4), prose(5)]
        #expect(TranscriptFold.runs(in: facts).runs.first?.rows == 0..<5)
    }

    // MARK: Whether one is folded right now

    private var run: TranscriptFold.Run {
        // Four calls at seqs 10 to 13, closed.
        TranscriptFold.runs(in: [tool(10), tool(11), tool(12), tool(13), prose(14)]).runs[0]
    }

    @Test("a closed run nobody has touched is folded")
    func aClosedRunIsFolded() {
        #expect(TranscriptFold.isFolded(run, unfolded: [], revealed: [], drawn: 0..<5))
    }

    @Test("the reader's own click wins")
    func theReaderCanOpenIt() {
        #expect(!TranscriptFold.isFolded(run, unfolded: [10], revealed: [], drawn: 0..<5))
    }

    /// A tool result the reader opened while the turn was running would otherwise vanish the moment
    /// the run around it closed.
    @Test("a run holding an opened tool result stays open")
    func anOpenedRowHoldsARunOpen() {
        #expect(!TranscriptFold.isFolded(run, unfolded: [], revealed: [12], drawn: 0..<5))
    }

    /// **The one that is worse than cosmetic.** A scroll can only find a row the table is DRAWING,
    /// so a search hit or an unread mark folded away is not a row somewhere off screen, it is a
    /// scroll that lands nowhere at all.
    @Test("a row something is aiming at is never hidden")
    func aSearchHitIsNeverHidden() {
        #expect(!TranscriptFold.isFolded(run, unfolded: [], revealed: [13], drawn: 0..<5))
        #expect(!TranscriptFold.isFolded(run, unfolded: [], revealed: [10], drawn: 0..<5))
        // And a seq outside the run is nothing to do with it.
        #expect(TranscriptFold.isFolded(run, unfolded: [], revealed: [9, 14], drawn: 0..<5))
    }

    /// The row a fold keeps on screen has to be a row that is on screen. A window that stops short
    /// of the last call would leave a line standing for rows and no row under it.
    @Test("a run whose last call is outside the drawn window does not fold")
    func aRunOutsideTheWindowDoesNotFold() {
        #expect(!TranscriptFold.isFolded(run, unfolded: [], revealed: [], drawn: 0..<3))
    }

    // MARK: The words

    /// The count goes into the label rather than into a grey oval, because macOS has already spent
    /// that shape on notification badges. See `TranscriptFold.label`.
    @Test("the line names what is hidden and how many")
    func theLabelSaysWhatIsHidden() {
        #expect(TranscriptFold.label(hiding: 6) == "6 earlier tool calls")
        #expect(TranscriptFold.label(hiding: 3) == "3 earlier tool calls")
    }

    /// The threshold is a constant somebody will lower one day, and the singular has to be there
    /// when they do.
    @Test("one hidden call is one earlier tool call")
    func theLabelHasASingular() {
        #expect(TranscriptFold.label(hiding: 1) == "1 earlier tool call")
    }

    // MARK: Finding a run by row

    @Test("a row index finds the run it is in, and only that one")
    func lookupByIndex() {
        let facts = [tool(0), tool(1), tool(2), tool(3), prose(4)]
            + (5..<10).map { tool($0) } + [prose(10)]
        let runs = TranscriptFold.runs(in: facts)
        #expect(runs.runs.count == 2)
        #expect(runs.run(containing: 0)?.firstSeq == 0)
        #expect(runs.run(containing: 3)?.firstSeq == 0)
        #expect(runs.run(containing: 4) == nil)
        #expect(runs.run(containing: 5)?.firstSeq == 5)
        #expect(runs.run(containing: 9)?.firstSeq == 5)
        #expect(runs.run(containing: 10) == nil)
        #expect(runs.run(containing: 99) == nil)
    }

    // MARK: Extending a scan

    /// Rows are appended and never reordered, so a scan only ever has to redo the tail. This is
    /// what keeps a turn's worth of arrivals off a walk of the whole session each time.
    @Test("extending a scan gives the same answer as scanning from nothing")
    func extendingMatchesAFullScan() {
        var facts: [TranscriptFold.Fact] = []
        var extended = TranscriptFold.Runs.none
        let script: [TranscriptFold.Fact] = [
            tool(0), quiet(1), tool(2), tool(3), tool(4), prose(5),
            tool(6), tool(7), quiet(8), tool(9), tool(10), tool(11), row(12, .result),
            tool(13), tool(14),
        ]
        for fact in script {
            facts.append(fact)
            extended = TranscriptFold.runs(in: facts, extending: extended)
            let whole = TranscriptFold.runs(in: facts)
            #expect(extended.runs == whole.runs, "after \(facts.count) rows")
            #expect(extended.resumeIndex == whole.resumeIndex, "after \(facts.count) rows")
            #expect(extended.scannedRows == whole.scannedRows, "after \(facts.count) rows")
        }
    }

    /// A session being replaced rather than grown, which is what a pane switching conversations
    /// hands this. Extending a longer scan into a shorter list has to start again.
    @Test("a shorter list than last time is scanned from the beginning")
    func aShorterListRescans() {
        let long = TranscriptFold.runs(in: (0..<20).map { tool($0) } + [prose(20)])
        let short = TranscriptFold.runs(in: closedRun, extending: long)
        #expect(short.runs == TranscriptFold.runs(in: closedRun).runs)
        #expect(short.scannedRows == 5)
    }

    /// The tail a rescan starts from is past the last row that broke a run, so a run that is still
    /// growing is rescanned and every closed one is left alone.
    @Test("a rescan resumes past the last row that broke a run")
    func resumeIsPastTheLastBreaker() {
        let runs = TranscriptFold.runs(in: closedRun + [tool(5), tool(6)])
        #expect(runs.resumeIndex == 5)
    }
}
