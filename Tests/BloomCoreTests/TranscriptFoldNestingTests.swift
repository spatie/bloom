import Foundation
import Testing
@testable import BloomCore

/// A subagent's rows fold the way a run of top level rows does.
///
/// **The bug this is written against.** Under a row reading "Agent: general-purpose", sixteen
/// consecutive nested actions were drawn one per line, with no "N actions" among them, while the
/// same run at the top level would have folded. Nested rows were scanned like any other, so they
/// sat in a group with the call that started the subagent, and that call has no result until the
/// subagent has finished. Rule 1 held the whole group open on it: the transcript uncollapsed for
/// as long as the subagent ran, which is exactly when folding it is worth most, and folded only
/// once it was over.
///
/// So the id a nested row carries is what ends a group, and the call that started the subagent is
/// held out of the fold as soon as a child of it appears. The rest of this suite is the two ways
/// that could go wrong: a fold swallowing the header, so an indented count hangs under a line that
/// no longer says which agent it stands for, and a fold reaching across two subagents into work
/// that is not the same agent's at all.
@Suite("Folding a subagent's rows")
struct FoldingASubagentsRowsTests {
    /// The call that starts a subagent. Unsettled, because that is the whole of the bug: its
    /// result does not come back until the subagent has finished.
    private func task(_ seq: Int, id: String, settled: Bool = false) -> TranscriptFold.Fact {
        TranscriptFold.Fact(seq: seq, kind: .toolUse, settled: settled, toolUseID: id)
    }

    private func nested(
        _ seq: Int, under parent: String, failed: Bool = false, settled: Bool = true
    ) -> TranscriptFold.Fact {
        TranscriptFold.Fact(
            seq: seq, kind: .toolUse, failed: failed, settled: settled, parentToolUseID: parent
        )
    }

    private func nestedProse(_ seq: Int, under parent: String) -> TranscriptFold.Fact {
        TranscriptFold.Fact(seq: seq, kind: .assistantText, parentToolUseID: parent)
    }

    private func tool(_ seq: Int) -> TranscriptFold.Fact {
        TranscriptFold.Fact(seq: seq, kind: .toolUse)
    }

    private func user(_ seq: Int) -> TranscriptFold.Fact {
        TranscriptFold.Fact(seq: seq, kind: .user)
    }

    private let everything = 0..<1_000

    private func hides(_ work: TranscriptFold.Work) -> Int {
        TranscriptFold.hides(work, revealed: [], drawn: everything)
    }

    // MARK: The run that was drawn in full

    /// The screenshot, written down: a subagent that is still working, sixteen of its actions
    /// below it, and one line standing for them.
    @Test("a running subagent's rows fold while it is still running")
    func aRunningSubagentFolds() throws {
        let facts = [user(0), tool(1), tool(2), task(3, id: "a")]
            + (4..<20).map { nested($0, under: "a") }
        let folds = TranscriptFold.folds(in: facts)
        let work = try #require(folds.all.last)
        #expect(work.rows.count == 16)
        #expect(work.isNested)
        #expect(hides(work) == 16)
    }

    /// **The reason the header is held out rather than left to fold with the work around it.** An
    /// indented "16 actions" hanging under a line that has folded away the row saying which agent
    /// it was is worse than not folding at all.
    @Test("the call that started the subagent is not swallowed by a fold")
    func theHeaderStaysVisible() {
        let facts = [user(0), tool(1), tool(2), task(3, id: "a")]
            + (4..<20).map { nested($0, under: "a") }
        let folds = TranscriptFold.folds(in: facts)
        #expect(folds.index(containing: 3) == nil)
    }

    /// A subagent's first row is often its own prose, which closes the group before the grouping
    /// by id would ever see the nesting. The header is held out on the sight of any child, which
    /// is what stops the run above it from folding over the top of it.
    @Test("the header stays visible when the subagent opens with prose")
    func theHeaderSurvivesNestedProse() throws {
        let facts = [user(0), tool(1), tool(2), tool(3), task(4, id: "a"), nestedProse(5, under: "a")]
            + (6..<10).map { nested($0, under: "a") }
        let folds = TranscriptFold.folds(in: facts)
        #expect(folds.index(containing: 4) == nil)
        // And the ordinary work above it folds without waiting for the subagent to finish.
        let above = try #require(folds.all.first)
        #expect(above.rows.count == 3)
        #expect(hides(above) == 3)
    }

    /// Prose from inside a subagent divides that subagent's own log, for the reason prose divides
    /// the log at the top level: it is what the agent found, not what it did.
    @Test("a subagent's prose closes its own group")
    func nestedProseClosesTheNestedGroup() throws {
        let facts = [user(0), task(1, id: "a"), nested(2, under: "a"), nestedProse(3, under: "a")]
            + (4..<7).map { nested($0, under: "a") }
        let folds = TranscriptFold.folds(in: facts)
        #expect(folds.all.count == 1)
        let work = try #require(folds.all.first)
        #expect(work.rows.map(\.seq) == [4, 5, 6])
        #expect(work.isNested)
    }

    // MARK: One fold never spans two agents

    @Test("two subagents in a row do not fold into one group")
    func twoSubagentsStaySeparate() {
        let facts = [user(0), task(1, id: "a")] + (2..<6).map { nested($0, under: "a") }
            + [task(6, id: "b")] + (7..<11).map { nested($0, under: "b") }
        let folds = TranscriptFold.folds(in: facts)
        #expect(folds.all.count == 2)
        #expect(folds.all.map(\.rows.count) == [4, 4])
        #expect(folds.all.map(\.isNested) == [true, true])
        #expect(folds.all.map(\.firstSeq) == [2, 7])
        // Both headers are still standing.
        #expect(folds.index(containing: 1) == nil)
        #expect(folds.index(containing: 6) == nil)
    }

    @Test("work after a subagent is the main agent's own group again")
    func topLevelWorkResumes() {
        let facts = [user(0), task(1, id: "a")] + (2..<6).map { nested($0, under: "a") }
            + (6..<10).map { tool($0) }
        let folds = TranscriptFold.folds(in: facts)
        #expect(folds.all.count == 2)
        #expect(folds.all.map(\.isNested) == [true, false])
        #expect(folds.all.map(\.rows.count) == [4, 4])
    }

    /// Two subagents running at once interleave their rows, so no run of either is long enough to
    /// fold. That is the honest answer for a transcript whose next line is a different agent's,
    /// and it is what the old code did for the whole run anyway.
    @Test("interleaved subagents fold nothing rather than folding together")
    func interleavedSubagentsDoNotFold() {
        var facts = [user(0), task(1, id: "a"), task(2, id: "b")]
        for step in 0..<6 {
            facts.append(nested(3 + step * 2, under: "a"))
            facts.append(nested(4 + step * 2, under: "b"))
        }
        let folds = TranscriptFold.folds(in: facts)
        #expect(folds.all.allSatisfy { hides($0) == 0 })
    }

    // MARK: Errors fold there too

    @Test("a failed call inside a subagent folds with the rest of its run")
    func aNestedFailureFolds() throws {
        let facts = [user(0), task(1, id: "a")]
            + (2..<12).map { nested($0, under: "a", failed: $0 == 6) }
        let folds = TranscriptFold.folds(in: facts)
        #expect(folds.all.count == 1)
        let work = try #require(folds.all.first)
        #expect(work.rows.count == 10)
        #expect(hides(work) == 10)
    }

    // MARK: Nothing unfolds

    /// A subagent's rows arrive one at a time, each result landing as the next call is issued,
    /// while the call that started it stays unsettled throughout. What is hidden may not go down
    /// on any of those passes.
    @Test("a subagent's fold only ever grows as its rows arrive")
    func aNestedFoldIsMonotone() {
        var facts = [user(0), task(1, id: "a")]
        var folds = TranscriptFold.Folds.none
        var seen: [Int: Int] = [:]

        for seq in 2..<16 {
            for at in facts.indices where facts[at].parentToolUseID != nil && !facts[at].settled {
                facts[at].settled = true
                facts[at].failed = facts[at].seq == 7
            }
            facts.append(nested(seq, under: "a", settled: false))
            folds = TranscriptFold.folds(in: facts, extending: folds)
            for work in folds.all {
                let now = hides(work)
                #expect(now >= (seen[work.firstSeq] ?? 0), "row \(seq) unfolded \(work.firstSeq)")
                seen[work.firstSeq] = now
            }
            #expect(folds.index(containing: 1) == nil, "row \(seq) hid the subagent's header")
        }
    }

    /// Rows are appended and never reordered, so a scan of a session with a subagent in it only
    /// ever has to redo the last turn, and has to agree with a scan from nothing while it does.
    @Test("extending a scan over nested rows matches a full scan")
    func extendingMatchesAFullScan() {
        var facts: [TranscriptFold.Fact] = []
        var extended = TranscriptFold.Folds.none
        let script: [TranscriptFold.Fact] = [
            user(0), tool(1), tool(2), task(3, id: "a"), nested(4, under: "a"),
            nested(5, under: "a"), nestedProse(6, under: "a"), nested(7, under: "a"),
            nested(8, under: "a", failed: true), nested(9, under: "a"), tool(10), tool(11),
            task(12, id: "b"), nested(13, under: "b"), nested(14, under: "b"), tool(15),
        ]
        for fact in script {
            facts.append(fact)
            extended = TranscriptFold.folds(in: facts, extending: extended)
            let whole = TranscriptFold.folds(in: facts)
            #expect(extended.all == whole.all, "after \(facts.count) rows")
            #expect(extended.resumeIndex == whole.resumeIndex, "after \(facts.count) rows")
        }
    }
}
