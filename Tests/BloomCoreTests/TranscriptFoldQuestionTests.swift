import Testing
@testable import BloomCore

@Suite("Agent questions stay in the chat")
struct TranscriptFoldQuestionTests {
    private func tool(_ seq: Int) -> TranscriptFold.Fact {
        TranscriptFold.Fact(seq: seq, kind: .toolUse)
    }

    @Test("question cards stay between activity groups before and after answering", arguments: [false, true])
    func questionsStayVisible(settled: Bool) {
        let facts = (0..<3).map { tool($0) }
            + [TranscriptFold.Fact(seq: 3, kind: .permissionAsk, featured: true, settled: settled)]
            + (4..<7).map { tool($0) }
            + [TranscriptFold.Fact(seq: 7, kind: .result)]

        let folds = TranscriptFold.folds(in: facts)
        #expect(folds.all.map(\.span) == [0..<3, 4..<7])
        #expect(folds.fold(containing: 3) == nil)
        let hidden = Set(folds.all.flatMap {
            TranscriptFold.hiddenIndices($0, revealed: [], drawn: facts.indices)
        })
        #expect(hidden == [0, 1, 2, 4, 5, 6])
    }

    @Test("answering a question and continuing work keeps the card visible")
    func answeringKeepsQuestionVisible() {
        var facts = (0..<3).map { tool($0) }
            + [TranscriptFold.Fact(seq: 3, kind: .permissionAsk, featured: true, settled: false)]
        var cache = TranscriptFoldCache()
        let waiting = cache.resolve(facts)
        #expect(waiting.fold(containing: 3) == nil)

        facts[3].settled = true
        cache.invalidate(row: 3)
        facts += (4..<7).map { tool($0) }
        facts.append(TranscriptFold.Fact(seq: 7, kind: .result))
        let answered = cache.resolve(facts)
        #expect(answered.all.map(\.span) == [0..<3, 4..<7])
        #expect(answered.fold(containing: 3) == nil)

        let reopened = TranscriptFold.folds(in: facts)
        #expect(reopened == answered)
    }
}
