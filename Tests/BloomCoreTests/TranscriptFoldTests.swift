import Foundation
import Testing
@testable import BloomCore

/// What forms a run of tool calls, what may be hidden while a turn is still running, and what
/// never may.
///
/// The decision is here rather than in `TranscriptListView` for the reason the three target split
/// exists. It is also the reason the fold is worth having at all: a run that draws as one entry is
/// a run whose other rows are never keyed, never measured and never built, and none of that could
/// be checked from inside a view.
///
/// **Half of this suite is about one property: what a fold hides only ever grows.** Folding while
/// the turn runs means hiding a call whose result has not come back, and a result can say the call
/// failed. Every rule that could react to that by revealing a row would be an unfold under a
/// reader who is watching the turn, which is worse than the interruption folding on completion was
/// avoiding. `monotone` below is that property written down against a scripted turn.
@Suite("Folding a run of tool calls")
struct TranscriptFoldTests {
    // MARK: Fixtures

    /// A call. Settled by default, because the interesting case is the one that is not.
    private func tool(
        _ seq: Int, failed: Bool = false, nested: Bool = false, settled: Bool = true
    ) -> TranscriptFold.Fact {
        TranscriptFold.Fact(
            seq: seq, kind: .toolUse, failed: failed, nested: nested,
            drawsNothing: false, settled: settled
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

    /// A window wide enough that nothing in these fixtures falls outside it.
    private let everything = 0..<1_000

    private func hides(_ run: TranscriptFold.Run, revealed: Set<Int> = []) -> Int {
        TranscriptFold.hides(run, revealed: revealed, drawn: everything)
    }

    /// The shape a turn is in mid stream: every call but the newest has its result back.
    private func streaming(_ count: Int) -> [TranscriptFold.Fact] {
        (0..<count).map { tool($0, settled: $0 < count - 1) }
    }

    // MARK: What forms a run

    @Test("consecutive tool calls are one run")
    func aRunIsFound() throws {
        let runs = TranscriptFold.runs(in: streaming(4) + [prose(4)])
        #expect(runs.runs.count == 1)
        let run = try #require(runs.runs.first)
        #expect(run.rows == 0..<4)
        #expect(run.firstSeq == 0)
        #expect(run.calls.map(\.seq) == [0, 1, 2, 3])
        // Three results back and the newest call still running, which is the shape a turn is in
        // mid stream and the reason the fourth is the row that stays.
        #expect(run.settled == 3)
    }

    /// **The owner's own screenshot**: `Read`, `Bash`, `Bash`, `Edit`, `Bash`, `Bash`, `Bash`, then
    /// prose. The kinds of tool are never consulted, so the `Edit` in the middle joins rather than
    /// cutting the run into a three and a three with a stray row between them.
    @Test("a mixed run of reads, edits and commands is one run")
    func aMixedRunJoins() {
        let runs = TranscriptFold.runs(in: streaming(7) + [prose(7)])
        #expect(runs.runs.count == 1)
        #expect(hides(runs.runs[0]) == 6)
    }

    /// The rule that decides whether there are any runs at all. Three to five `system` rows sit
    /// between every pair of tool calls in a real session, and letting one break a run would mean
    /// no run in any transcript ever reached four.
    @Test("rows that draw nothing sit inside a run without breaking it or being counted")
    func quietRowsAreTransparent() throws {
        let facts = [
            tool(0), quiet(1), quiet(2), tool(3), quiet(4), tool(5), tool(6, settled: false),
        ]
        let runs = TranscriptFold.runs(in: facts)
        #expect(runs.runs.count == 1)
        let run = try #require(runs.runs.first)
        // The run spans the quiet rows it swallowed, and counts only the four calls.
        #expect(run.rows == 0..<7)
        #expect(run.calls.map(\.index) == [0, 3, 5, 6])
        #expect(hides(run) == 3)
    }

    /// A run ends at its last call. Stretching it over the rows after it would make its span a
    /// guess about what the next turn is going to say.
    @Test("a run ends at its last call, not at the quiet rows after it")
    func trailingQuietRowsStayOutside() {
        let runs = TranscriptFold.runs(in: streaming(4) + [quiet(4), quiet(5), prose(6)])
        #expect(runs.runs.first?.rows == 0..<4)
    }

    @Test("everything the reader would have read breaks a run")
    func drawingRowsBreakARun() {
        let breakers: [MessageKind] = [
            .assistantText, .thinking, .user, .permissionAsk, .error, .notice, .result, .toolResult,
        ]
        for kind in breakers {
            let runs = TranscriptFold.runs(in: [
                tool(0), tool(1), row(2, kind), tool(3), tool(4), tool(5), tool(6),
            ])
            // Two groups of two and one of four, and only the long one can hide anything.
            #expect(runs.runs.count == 2, "\(kind) should have cut the run in two")
            #expect(runs.runs.first.map { hides($0) } == 0, "\(kind)")
            #expect(runs.runs.last.map { hides($0) } == 3, "\(kind)")
        }
    }

    /// A session start is a `system` row that DOES draw, so it breaks a run like anything else the
    /// reader can see. `TranscriptRowInk` is what tells the two apart.
    @Test("a system row that draws breaks a run, and one that does not never did")
    func aDrawingSystemRowBreaksARun() {
        let drawing = TranscriptFold.Fact(
            seq: 2, kind: .system, failed: false, nested: false, drawsNothing: false
        )
        let runs = TranscriptFold.runs(in: [tool(0), tool(1), drawing, tool(3), tool(4)])
        #expect(runs.runs.count == 2)
        #expect(runs.runs.map(\.rows) == [0..<2, 3..<5])
    }

    /// A subagent's rows are drawn indented under the call that started them. Swallowing two indent
    /// levels into one line would be a fold that lies about where its calls happened.
    @Test("a change of indent starts a new run rather than lengthening one")
    func nestingBreaksARun() {
        let facts = (0..<4).map { tool($0) } + (4..<8).map { tool($0, nested: true) }
        let runs = TranscriptFold.runs(in: facts)
        #expect(runs.runs.count == 2)
        #expect(runs.runs.map(\.rows) == [0..<4, 4..<8])
    }

    // MARK: The fold's own entry, and when it joins the list

    /// **The gap between `leastGroup` and `leastRun` is what keeps folding off `reloadData`.** The
    /// fold's line is an entry, and an entry that appeared on the same pass that rows left the list
    /// would be two edits `TranscriptEntryChange` can only call `.rebuilt`. In from the second call,
    /// the pass that folds a run is a removal and nothing else.
    @Test("a lone tool call is not a run and gets no line")
    func oneCallIsNotARun() {
        #expect(TranscriptFold.runs(in: [tool(0), prose(1)]).runs.isEmpty)
    }

    @Test("a group gets its line from the second call, long before it can fold")
    func theLineArrivesEarly() {
        #expect(TranscriptFold.leastGroup < TranscriptFold.leastRun)
        for length in TranscriptFold.leastGroup..<TranscriptFold.leastRun {
            let runs = TranscriptFold.runs(in: streaming(length))
            #expect(runs.runs.count == 1, "\(length) calls should still be a run")
            #expect(runs.runs.map { hides($0) } == [0], "\(length) calls should hide nothing")
        }
    }

    /// Three calls fold to a line and a row, which is two lines where three were: one line bought
    /// for a control and a decision. Four halves the run, which is where it starts to pay.
    @Test("a run folds at four calls and not at three")
    func theThreshold() {
        #expect(hides(TranscriptFold.runs(in: streaming(3)).runs[0]) == 0)
        #expect(hides(TranscriptFold.runs(in: streaming(4)).runs[0]) == TranscriptFold.leastRun - 1)
    }

    // MARK: Folding while the turn is still running

    /// **The change the owner asked for.** The first spelling waited for a run to be closed by a
    /// following drawn row; a run at the live end of a running turn now folds as soon as it is long
    /// enough, so a turn's log is one line and the call happening right now.
    @Test("a run still growing at the end of the rows folds")
    func anOpenRunFolds() {
        let runs = TranscriptFold.runs(in: streaming(7))
        #expect(runs.runs.count == 1)
        #expect(hides(runs.runs[0]) == 6)
    }

    /// And the row it keeps is the newest call, running or finished. A fold that hid that would
    /// have taken away the one thing it was asked to keep.
    @Test("the newest call is never hidden")
    func theNewestCallStays() throws {
        for length in TranscriptFold.leastRun...12 {
            let run = try #require(TranscriptFold.runs(in: streaming(length)).runs.first)
            #expect(hides(run) == length - 1)
            #expect(run.calls[hides(run)].seq == length - 1)
        }
    }

    /// **Rule 1.** A call whose result has not come back can still change what it says, so it is
    /// drawn until it has. A burst of parallel calls arrives with no results at all, and is simply
    /// drawn until they land.
    @Test("a call whose result has not arrived is never hidden")
    func unsettledCallsAreNeverHidden() throws {
        let parallel = (0..<6).map { tool($0, settled: false) }
        #expect(hides(TranscriptFold.runs(in: parallel).runs[0]) == 0)

        // Four of the six back, which is three that may be hidden and one that may not.
        let partly = (0..<6).map { tool($0, settled: $0 < 4) }
        let run = try #require(TranscriptFold.runs(in: partly).runs.first)
        #expect(run.settled == 4)
        #expect(hides(run) == 4)
    }

    /// The prefix stops at the first call still waiting, so a later result cannot reach over one
    /// that has not come back.
    @Test("a settled call behind an unsettled one is still not hidden")
    func theSettledPrefixHasNoGaps() {
        let facts = [tool(0), tool(1), tool(2, settled: false), tool(3), tool(4), tool(5)]
        #expect(TranscriptFold.runs(in: facts).runs[0].settled == 2)
        #expect(hides(TranscriptFold.runs(in: facts).runs[0]) == 0)
    }

    // MARK: Failures

    /// **Rule 2, and the rule that had to change when folding moved to arrival.** "A run holding a
    /// failure does not fold" cannot survive a failure arriving after the fold: it would unfold
    /// under the reader. Closing the run at the failure keeps the promise that matters, which is
    /// that the failed call is the row on screen rather than the thing hidden.
    @Test("a failed call closes the run around itself and is the row that stays")
    func aFailureClosesTheRun() throws {
        let facts = (0..<4).map { tool($0, failed: $0 == 3) } + (4..<9).map { tool($0) }
        let runs = TranscriptFold.runs(in: facts)
        #expect(runs.runs.count == 2)
        let failing = try #require(runs.runs.first)
        #expect(failing.rows == 0..<4)
        // Three hidden and the failure shown, which is what a fold of four looks like whatever
        // closed it.
        #expect(hides(failing) == 3)
        #expect(failing.calls[3].seq == 3)
        #expect(runs.runs.last?.rows == 4..<9)
    }

    /// A failure early in a group leaves too little in front of it to fold, and that is the right
    /// answer: the two calls before it are drawn beside it.
    @Test("a failure near the front leaves a group too short to hide anything")
    func anEarlyFailureHidesNothing() {
        let facts = (0..<3).map { tool($0, failed: $0 == 2) } + (3..<8).map { tool($0) }
        let runs = TranscriptFold.runs(in: facts)
        #expect(runs.runs.count == 2)
        #expect(hides(runs.runs[0]) == 0)
        #expect(hides(runs.runs[1]) == 4)
    }

    /// **The invariant the monotonicity rests on, spelled rather than trusted.** A result writes
    /// `is_error` and the payload in one go, so a failure has settled by definition; a caller that
    /// let the two come apart would let a hidden call turn into a failure and force an unfold.
    @Test("a failure counts as settled whatever the caller said")
    func aFailureIsSettled() {
        let facts = (0..<5).map { tool($0, failed: $0 == 4, settled: $0 != 4) }
        let runs = TranscriptFold.runs(in: facts)
        #expect(runs.runs[0].settled == 5)
        #expect(hides(runs.runs[0]) == 4)
    }

    // MARK: What something has asked to see

    /// **Rule 3.** A tool result the reader opened is a row they are reading. Refusing to fold at
    /// all would unfold a run that had already folded, so the prefix stops there instead and the
    /// opened call is drawn beside the newest one.
    @Test("an opened call cuts the prefix short rather than unfolding the run")
    func anOpenedCallCapsThePrefix() {
        let run = TranscriptFold.runs(in: streaming(9)).runs[0]
        #expect(hides(run) == 8)
        #expect(hides(run, revealed: [5]) == 5)
        // And a call further along cuts it no further than it already was.
        #expect(hides(run, revealed: [7, 5]) == 5)
    }

    /// **The one that is worse than cosmetic.** A scroll can only find a row the table is DRAWING,
    /// so a search hit or an unread mark hidden inside a fold is not a row somewhere off screen, it
    /// is a scroll that lands nowhere at all.
    @Test("a row something is aiming at is never hidden")
    func aSearchHitIsNeverHidden() {
        let run = TranscriptFold.runs(in: streaming(9)).runs[0]
        for seq in 0..<8 {
            #expect(hides(run, revealed: [seq]) <= seq, "call \(seq) must still be drawn")
        }
        // A seq outside the run is nothing to do with it, and neither is the call already shown.
        #expect(hides(run, revealed: [99]) == 8)
        #expect(hides(run, revealed: [8]) == 8)
    }

    // MARK: The window

    /// The row a fold keeps on screen has to be a row that is on screen. A window that stops short
    /// of the first call that stays would leave a line standing over nothing.
    @Test("a run whose surviving call is outside the drawn window does not fold")
    func aRunOutsideTheWindowDoesNotFold() {
        let run = TranscriptFold.runs(in: streaming(5)).runs[0]
        #expect(TranscriptFold.hides(run, revealed: [], drawn: 0..<5) == 4)
        #expect(TranscriptFold.hides(run, revealed: [], drawn: 0..<4) == 0)
    }

    /// Rows above the window are not drawn either way, so hiding them changes nothing that is on
    /// screen. What matters is that the hidden set is an absolute range of rows rather than one
    /// measured from the window, so a window grown upwards puts rows in without taking any out.
    @Test("the window's start does not move what is hidden")
    func growingTheWindowUpwardsTakesNothingOut() {
        let run = TranscriptFold.runs(in: streaming(9)).runs[0]
        #expect(TranscriptFold.hides(run, revealed: [], drawn: 6..<20) == 8)
        #expect(TranscriptFold.hides(run, revealed: [], drawn: 0..<20) == 8)
    }

    // MARK: Nothing unfolds

    /// **The property the whole design is arranged around, against a scripted turn.**
    ///
    /// Nine calls arrive one at a time, each one's result landing as the next is issued, with the
    /// fifth coming back a failure and the reader opening the seventh while it is on screen. At no
    /// point may the number of hidden calls in a run go down, because a run that reveals a row it
    /// had hidden is a transcript rearranging itself under somebody who is reading it.
    @Test("what a fold hides only ever grows")
    func monotone() {
        var facts: [TranscriptFold.Fact] = []
        var runs = TranscriptFold.Runs.none
        var seen: [Int: Int] = [:]
        let revealed: Set<Int> = [6]

        for seq in 0..<9 {
            // The result of the call before this one comes back as this one is issued, which is
            // the order the CLI writes them in. The fifth comes back a failure.
            for at in facts.indices where facts[at].kind == .toolUse && !facts[at].settled {
                facts[at].settled = true
                facts[at].failed = facts[at].seq == 4
            }
            facts.append(tool(seq, settled: false))
            runs = TranscriptFold.runs(in: facts, extending: runs)
            for run in runs.runs {
                let now = hides(run, revealed: revealed)
                #expect(now >= (seen[run.firstSeq] ?? 0), "run \(run.firstSeq) unfolded at row \(seq)")
                seen[run.firstSeq] = now
            }
        }
        // And the turn ends: the last result comes back and the answer lands after it.
        for at in facts.indices where facts[at].kind == .toolUse { facts[at].settled = true }
        facts.append(prose(9))
        runs = TranscriptFold.runs(in: facts, extending: runs)
        for run in runs.runs {
            #expect(hides(run, revealed: revealed) >= (seen[run.firstSeq] ?? 0))
        }
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
        let facts = (0..<4).map { tool($0) } + [prose(4)] + (5..<10).map { tool($0) }
        let runs = TranscriptFold.runs(in: facts)
        #expect(runs.runs.count == 2)
        #expect(runs.run(containing: 0)?.firstSeq == 0)
        #expect(runs.run(containing: 3)?.firstSeq == 0)
        #expect(runs.run(containing: 4) == nil)
        #expect(runs.run(containing: 5)?.firstSeq == 5)
        #expect(runs.run(containing: 9)?.firstSeq == 5)
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
            tool(6), tool(7), quiet(8), tool(9, failed: true), tool(10), tool(11),
            row(12, .result), tool(13), tool(14, settled: false),
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
        let long = TranscriptFold.runs(in: (0..<20).map { tool($0) })
        let short = TranscriptFold.runs(in: streaming(4), extending: long)
        #expect(short.runs == TranscriptFold.runs(in: streaming(4)).runs)
        #expect(short.scannedRows == 4)
    }

    /// **A rescan resumes past the last row that BROKE a run, not past the last run.** A run cut
    /// short by a failure or by a change of indent is still open to being cut somewhere else when
    /// a result lands, and a run with a call still running has a settled prefix that is going to
    /// grow. Only a drawn row between two runs settles everything above it.
    @Test("a rescan resumes past the last row that broke a run")
    func resumeIsPastTheLastBreaker() {
        #expect(TranscriptFold.runs(in: streaming(4) + [prose(4), tool(5), tool(6)]).resumeIndex == 5)
        // A failure closes a run and does not settle what follows it.
        #expect(TranscriptFold.runs(in: [tool(0, failed: true), tool(1), tool(2)]).resumeIndex == 0)
    }
}
