import Testing
@testable import BloomCore

@Suite("An answer too long to build twice")
struct TranscriptLongAnswerTests {
    @Test("a long answer is estimated in proportion to its size instead of being measured off screen")
    func longAnswerIsEstimated() throws {
        let threshold = TranscriptLongAnswer.threshold
        let long = try #require(TranscriptLongAnswer.estimate(kind: .assistantText, payloadBytes: threshold))
        let twice = try #require(TranscriptLongAnswer.estimate(kind: .assistantText, payloadBytes: threshold * 2))
        #expect(long > 0)
        #expect(abs(twice - 2 * long) < 1)
    }

    @Test("a short answer, or a long row of another kind, is measured as usual")
    func othersAreMeasured() {
        let threshold = TranscriptLongAnswer.threshold
        #expect(TranscriptLongAnswer.estimate(kind: .assistantText, payloadBytes: threshold - 1) == nil)
        #expect(TranscriptLongAnswer.estimate(kind: .toolResult, payloadBytes: threshold * 7) == nil)
        #expect(TranscriptLongAnswer.estimate(kind: .user, payloadBytes: threshold * 7) == nil)
    }
}
