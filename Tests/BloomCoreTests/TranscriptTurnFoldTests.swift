import Foundation
import Testing
@testable import BloomCore

@Suite("Completed turn boundaries")
struct TranscriptTurnFoldTests {
    private func fact(
        _ seq: Int,
        _ kind: MessageKind,
        parent: String? = nil,
        durationMS: Int? = nil,
        createdAt: TimeInterval? = nil
    ) -> TranscriptTurnFold.Fact {
        TranscriptTurnFold.Fact(
            seq: seq,
            kind: kind,
            parentToolUseID: parent,
            durationMS: durationMS,
            createdAt: createdAt.map(Date.init(timeIntervalSince1970:))
        )
    }

    @Test("held turns are kept for the session they were scanned from")
    func heldTurnsKept() {
        let held = TranscriptTurnFold.folds(in: [fact(0, .user), fact(1, .assistantText), fact(2, .result)])
        let session = SessionID("shown")
        #expect(!TranscriptTurnFold.takesFreshTurns(held: held, heldFor: session, showing: session))
        #expect(TranscriptTurnFold.takesFreshTurns(held: held, heldFor: session, showing: SessionID("other")))
        #expect(TranscriptTurnFold.takesFreshTurns(held: held, heldFor: nil, showing: session))
    }

    @Test("turns held from an empty conversation are scanned again at once")
    func emptyHeldTurnsRescanned() {
        let session = SessionID("shown")
        #expect(TranscriptTurnFold.takesFreshTurns(held: .none, heldFor: session, showing: session))
    }

    @Test("a result closes the turn after the agent's response")
    func completedTurn() throws {
        let facts = [
            fact(0, .user),
            fact(1, .assistantText),
            fact(2, .toolUse),
            fact(3, .assistantText),
            fact(4, .result, durationMS: 65_000),
        ]
        let folds = TranscriptTurnFold.folds(in: facts)
        let turn = try #require(folds.all.first)

        #expect(turn.firstSeq == 1)
        #expect(turn.span == 1..<5)
        #expect(turn.isComplete)
        #expect(turn.durationMS == 65_000)
        #expect(folds.turn(containing: 1) == turn)
        #expect(folds.turn(containing: 3) == turn)
        #expect(folds.turn(containing: 5) == nil)
        #expect(TranscriptTurnFold.label(milliseconds: 65_000) == "Worked for 1m 5s")
    }

    @Test("a live turn has no duration yet")
    func liveTurn() throws {
        let facts = [fact(0, .user), fact(1, .assistantText), fact(2, .toolUse)]
        let turn = try #require(TranscriptTurnFold.folds(in: facts).all.first)

        #expect(!turn.isComplete)
        #expect(turn.durationMS == nil)
        #expect(turn.span == 1..<3)
    }

    @Test("a direct response still has a turn boundary")
    func directResponse() throws {
        let facts = [fact(0, .user), fact(1, .assistantText), fact(2, .result, durationMS: 800)]
        let turn = try #require(TranscriptTurnFold.folds(in: facts).all.first)

        #expect(turn.span == 1..<3)
        #expect(turn.durationMS == 800)
    }

    @Test("a missing backend duration is measured from turn timestamps")
    func measuredDuration() throws {
        let facts = [
            fact(0, .user, createdAt: 100),
            fact(1, .toolUse, createdAt: 102),
            fact(2, .assistantText, createdAt: 113),
            fact(3, .result, durationMS: 0, createdAt: 114),
        ]
        let turn = try #require(TranscriptTurnFold.folds(in: facts).all.first)

        #expect(turn.durationMS == 14_000)
        #expect(TranscriptTurnFold.label(milliseconds: 0) == "Worked for a while")
    }

    @Test("a background wake starts new work without closing the previous turn")
    func backgroundWake() throws {
        let facts = [
            fact(0, .user, createdAt: 100),
            fact(1, .assistantText, createdAt: 102),
            fact(2, .toolUse, createdAt: 104),
            TranscriptTurnFold.Fact(
                seq: 3, kind: .system, opensTurn: true,
                createdAt: Date(timeIntervalSince1970: 110)
            ),
            fact(4, .toolUse, createdAt: 111),
            fact(5, .assistantText, createdAt: 113),
            fact(6, .result, durationMS: 14_000, createdAt: 114),
        ]
        let turns = TranscriptTurnFold.folds(in: facts).all

        #expect(turns.count == 1)
        #expect(turns[0].firstSeq == 4)
        #expect(turns[0].span == 4..<7)
        #expect(turns[0].durationMS == 4_000)
    }

    @Test("a steering message closes the previous turn before its own bubble")
    func steeringMessage() throws {
        let facts = [
            fact(0, .user, createdAt: 100),
            fact(1, .assistantText, createdAt: 102),
            fact(2, .toolUse, createdAt: 104),
            fact(3, .user, createdAt: 110),
            fact(4, .toolUse, createdAt: 111),
            fact(5, .assistantText, createdAt: 113),
            fact(6, .result, durationMS: 14_000, createdAt: 114),
        ]
        let folds = TranscriptTurnFold.folds(in: facts)

        #expect(folds.all.count == 2)
        #expect(folds.all[0].span == 1..<3)
        #expect(folds.all[0].durationMS == 10_000)
        #expect(folds.turn(endingAt: 3) == folds.all[0])
        #expect(folds.all[1].span == 4..<7)
        #expect(folds.all[1].durationMS == 4_000)
        #expect(folds.turn(endingAt: 4) == nil)
    }

    @Test("a nested result does not close the main agent's turn")
    func nestedResult() throws {
        let facts = [
            fact(0, .user),
            fact(1, .toolUse),
            fact(2, .result, parent: "subagent"),
            fact(3, .assistantText),
            fact(4, .result, durationMS: 2_000),
        ]
        let turn = try #require(TranscriptTurnFold.folds(in: facts).all.first)

        #expect(turn.span == 1..<5)
        #expect(turn.durationMS == 2_000)
    }

    @Test("activity groups report the rows their own disclosure hides")
    func availableActivity() {
        func work(_ start: Int) -> TranscriptFold.Work {
            TranscriptFold.Work(
                span: start..<(start + 3),
                rows: (start..<(start + 3)).map { TranscriptFold.Row(index: $0, seq: $0) },
                ready: Set(start..<(start + 3)),
                hasAnswer: true
            )
        }
        let groups = TranscriptFold.Folds(all: [work(1), work(6)], scannedRows: 9, resumeIndex: 5)

        let shown = TranscriptTurnFold.hiddenActivity(
            work: groups, revealed: [], drawn: 0..<9
        )
        #expect(shown[1] == [1, 2, 3])
        #expect(shown[6] == [6, 7, 8])

        let clipped = TranscriptTurnFold.hiddenActivity(
            work: groups, revealed: [], drawn: 2..<9
        )
        #expect(clipped[1] == nil)
    }

    @Test("the turn disclosure folds interim prose and actions but keeps the final answer")
    func workBeforeAnswer() {
        let turn = TranscriptTurnFold.Turn(
            span: 1..<7, firstSeq: 1, isComplete: true, durationMS: 15_000
        )
        let rows = (0..<7).map { TranscriptTurnFold.Visibility(seq: $0) }
        #expect(TranscriptTurnFold.foldedWork(
            turn: turn, answerIndex: 5, in: rows, revealed: [], drawn: 0..<7
        ) == 1..<5)
    }

    @Test("a revealed row, a partial window or work that is all kept visible folds nothing")
    func protectedWork() {
        let turn = TranscriptTurnFold.Turn(span: 1..<7, firstSeq: 1, isComplete: true)
        var rows = (0..<7).map { TranscriptTurnFold.Visibility(seq: $0) }
        rows[3].keepsVisible = true
        #expect(TranscriptTurnFold.foldedWork(
            turn: turn, answerIndex: 5, in: rows, revealed: [], drawn: 0..<7
        ) == 1..<5)
        #expect(TranscriptTurnFold.foldedWork(
            turn: turn, answerIndex: 5, in: rows, revealed: [2], drawn: 0..<7
        ) == nil)
        #expect(TranscriptTurnFold.foldedWork(
            turn: turn, answerIndex: 5, in: rows, revealed: [], drawn: 2..<7
        ) == nil)
        for index in 1..<5 { rows[index].keepsVisible = true }
        #expect(TranscriptTurnFold.foldedWork(
            turn: turn, answerIndex: 5, in: rows, revealed: [], drawn: 0..<7
        ) == nil)
    }

    @Test("a row is collapsed when it falls in the work of a collapsed turn and nowhere else")
    func collapsedSpans() {
        var collapsed = TranscriptTurnFold.Collapsed()
        collapsed.add(1..<5)
        collapsed.add(9..<12)
        collapsed.add(20..<21)
        let inside = (0..<25).filter { collapsed.contains($0) }
        #expect(inside == [1, 2, 3, 4, 9, 10, 11, 20])
        #expect(!TranscriptTurnFold.Collapsed().contains(0))
    }

    @Test("an incremental scan keeps completed turns and updates the live tail")
    func extending() {
        var facts = [
            fact(0, .user),
            fact(1, .toolUse),
            fact(2, .assistantText),
            fact(3, .result, durationMS: 1_000),
            fact(4, .user),
            fact(5, .assistantText),
        ]
        var folds = TranscriptTurnFold.folds(in: facts)
        facts.append(fact(6, .toolUse))
        folds = TranscriptTurnFold.folds(in: facts, extending: folds)
        facts.append(fact(7, .assistantText))
        facts.append(fact(8, .result, durationMS: 2_000))
        folds = TranscriptTurnFold.folds(in: facts, extending: folds)

        #expect(folds == TranscriptTurnFold.folds(in: facts))
        #expect(folds.all.map(\.firstSeq) == [1, 5])
    }
}
