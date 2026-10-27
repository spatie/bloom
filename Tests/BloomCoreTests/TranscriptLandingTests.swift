import Testing
@testable import BloomCore

@Suite("Where a remembered row lands")
struct TranscriptLandingTests {
    private let ids: [TranscriptEntryID] = [
        .setup, .row(1), .turnFold(3), .row(12), .answerPart(seq: 12, part: 1), .row(20), .streaming,
    ]

    @Test("a row still drawn is its own entry")
    func exact() {
        #expect(TranscriptLanding.index(of: 12, in: ids) == 3)
    }

    @Test("a row folded away lands on the fold now hiding it")
    func folded() {
        #expect(TranscriptLanding.index(of: 7, in: ids) == 2)
    }

    @Test("a row hidden after a long answer lands on that answer's last part")
    func afterLongAnswer() {
        #expect(TranscriptLanding.index(of: 15, in: ids) == 4)
    }

    @Test("a row before everything drawn has nowhere to land")
    func beforeEverything() {
        #expect(TranscriptLanding.index(of: 0, in: ids) == nil)
    }
}
