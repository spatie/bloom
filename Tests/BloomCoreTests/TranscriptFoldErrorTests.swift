import Foundation
import Testing
@testable import BloomCore

/// An errored action folds away with the ordinary work around it.
///
/// **The bug this is written against.** A row whose call had failed was held out of the fold and
/// left standing on its own between two folded groups, so a single run of work was drawn as "7
/// actions", one errored fetch, "42 actions", one errored search, "88 actions". The rows meant to
/// be easy to find were chopping up the transcript instead, and there were enough of them to do it
/// twice in one screenful. A tool that fails is ordinary: agents probe with calls that are allowed
/// to miss, and the prose that ends the run says what actually went wrong.
///
/// **What did not change is the other half of the old rule.** An `error` row is the agent exiting
/// in a way it did not choose, which is the one failure no later prose will explain because there
/// is no later prose, and a `featured` row is deliberate content wearing an activity row's
/// clothes. Both still divide the work around them, and the tests at the foot of this suite are
/// the boundary the change was allowed to move up to and no further.
@Suite("Folding an errored action")
struct FoldingAnErroredActionTests {
    private func tool(_ seq: Int, failed: Bool = false, settled: Bool = true) -> TranscriptFold.Fact {
        TranscriptFold.Fact(seq: seq, kind: .toolUse, failed: failed, settled: settled)
    }

    private func media(_ seq: Int) -> TranscriptFold.Fact {
        TranscriptFold.Fact(seq: seq, kind: .toolUse, featured: true)
    }

    private func agentExit(_ seq: Int) -> TranscriptFold.Fact {
        TranscriptFold.Fact(seq: seq, kind: .error)
    }

    private func prose(_ seq: Int) -> TranscriptFold.Fact {
        TranscriptFold.Fact(seq: seq, kind: .assistantText)
    }

    private func user(_ seq: Int) -> TranscriptFold.Fact {
        TranscriptFold.Fact(seq: seq, kind: .user)
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

    // MARK: An error inside a run

    @Test("a failed call in the middle of a run folds with the rest of it")
    func aFailureInTheMiddleFolds() throws {
        let facts = [user(0)] + (1..<10).map { tool($0, failed: $0 == 5) }
        let work = try only(facts)
        #expect(work.rows.count == 9)
        #expect(hides(work) == 9)
        // The errored row is inside the working rather than standing between two of them.
        let folds = TranscriptFold.folds(in: facts)
        #expect(folds.fold(containing: 5)?.firstSeq == 1)
    }

    /// The screenshot that started this, written down: three runs of ordinary work and the two
    /// errors between them are one group, not five entries.
    @Test("the reported transcript folds into a single group")
    func theReportedTranscript() throws {
        var facts = [user(0)]
        facts += (1...7).map { tool($0) }
        facts.append(tool(8, failed: true))
        facts += (9...50).map { tool($0) }
        facts.append(tool(51, failed: true))
        facts += (52...139).map { tool($0) }
        let work = try only(facts)
        #expect(work.rows.count == 139)
        #expect(hides(work) == 139)
    }

    @Test("a run that opens with a failed call folds from its first row")
    func aFailureAtTheStartFolds() throws {
        let work = try only([user(0), tool(1, failed: true), tool(2), tool(3), tool(4)])
        #expect(work.rows.first?.seq == 1)
        #expect(work.rows.count == 4)
        #expect(hides(work) == 4)
    }

    @Test("a run that ends on a failed call folds through it")
    func aFailureAtTheEndFolds() throws {
        let work = try only([user(0), tool(1), tool(2), tool(3), tool(4, failed: true)])
        #expect(work.rows.count == 4)
        #expect(hides(work) == 4)
    }

    /// Two failures in a row are still one run, and the ordinary work on either side of them is
    /// not split into three entries the way it was.
    @Test("consecutive failures do not start a new group")
    func consecutiveFailuresFoldTogether() throws {
        let facts = [user(0)]
            + (1..<41).map { tool($0) }
            + [tool(41, failed: true), tool(42, failed: true)]
            + (43..<63).map { tool($0) }
        let work = try only(facts)
        #expect(work.rows.count == 62)
        #expect(hides(work) == 62)
    }

    /// A refusal travels as `is_error` too, so it is the same fact here and folds the same way.
    /// The permission question it came from folds once it has been answered, and burying the
    /// answer while leaving the refused call standing would be half a rule.
    @Test("a refused call folds like any other settled row")
    func aRefusalFolds() throws {
        let work = try only([user(0)] + (1..<8).map { tool($0, failed: $0 == 3) })
        #expect(hides(work) == 7)
    }

    // MARK: Nothing unfolds under the reader

    /// **The property folding a failure could have broken.** A call is hidden before its result
    /// comes back, and that result can say it failed. The failure no longer changes what may be
    /// hidden, so a fold does not have to give a row back to say so.
    @Test("a hidden call coming back a failure does not unfold anything")
    func aLateFailureDoesNotUnfold() {
        var facts = [user(0)]
        var folds = TranscriptFold.Folds.none
        var seen: [Int: Int] = [:]

        for seq in 1..<12 {
            for at in facts.indices where facts[at].kind == .toolUse && !facts[at].settled {
                facts[at].settled = true
                facts[at].failed = facts[at].seq == 5 || facts[at].seq == 9
            }
            facts.append(tool(seq, settled: false))
            folds = TranscriptFold.folds(in: facts, extending: folds)
            for work in folds.all {
                let now = hides(work)
                #expect(now >= (seen[work.firstSeq] ?? 0), "row \(seq) unfolded \(work.firstSeq)")
                seen[work.firstSeq] = now
            }
        }
        #expect(folds.all.count == 1)
        // One group over the whole turn, with both failures inside it.
        #expect(folds.all.first?.rows.count == 11)
    }

    /// **Why the fold's line is not marked when it hides a failure.** A reader who is looking for
    /// one is not left to spot a badge: rule 4 pulls a row something is aiming at, a search hit or
    /// an unread mark, out of whatever fold it sits in, and the disclosure opens the rest.
    @Test("an errored row a reader is taken to is still not hidden")
    func aFailureSomethingAimsAtIsDrawn() throws {
        let work = try only([user(0)] + (1..<10).map { tool($0, failed: $0 == 5) })
        #expect(hides(work) == 9)
        #expect(hides(work, revealed: [5]) == 4)
    }

    /// And the line says only what it always said. The count is the whole of it, so a fold that
    /// holds a failure reads the same as one that does not.
    @Test("the line stays a plain count")
    func theLineIsAPlainCount() {
        #expect(TranscriptFold.label(hiding: 139) == "139 actions")
    }

    // MARK: The boundary the change stopped at

    /// The agent exiting is not an action that failed, it is the turn dying, and nothing later
    /// explains it because there is nothing later. It still divides the work around it.
    @Test("an agent error row still separates two groups")
    func anAgentErrorStillSeparates() {
        let facts = [user(0)] + (1..<5).map { tool($0) } + [agentExit(5)]
            + (6..<10).map { tool($0) }
        let folds = TranscriptFold.folds(in: facts)
        #expect(folds.all.count == 2)
        #expect(folds.all.map(\.rows.count) == [4, 4])
        #expect(folds.index(containing: 5) == nil)
    }

    /// Inline media is content the agent chose to show, not part of the implementation log, so it
    /// stays visible for the same reason prose does.
    @Test("a featured row still separates two groups")
    func featuredContentStillSeparates() {
        let facts = [user(0)] + (1..<5).map { tool($0) } + [media(5)] + (6..<10).map { tool($0) }
        let folds = TranscriptFold.folds(in: facts)
        #expect(folds.all.count == 2)
        #expect(folds.all.map(\.rows.count) == [4, 4])
        #expect(folds.index(containing: 5) == nil)
    }

    /// Prose is unchanged too: it closes the work above it as answered, and a failure inside that
    /// work does not stop it doing so.
    @Test("prose still closes a group that holds a failure")
    func proseStillClosesAGroup() {
        let facts = [user(0)] + (1..<5).map { tool($0, failed: $0 == 2) } + [prose(5)]
            + (6..<10).map { tool($0) }
        let folds = TranscriptFold.folds(in: facts)
        #expect(folds.all.count == 2)
        #expect(folds.all.map(\.rows.count) == [4, 4])
        #expect(folds.all.map(\.hasAnswer) == [true, false])
    }
}
