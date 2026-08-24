import Foundation
import Testing
@testable import BloomCore

@Suite("Transcript tail")
struct TranscriptTailTests {
    /// A session of `count` rows with a result row every `turn` rows, which is the shape a real
    /// one has: a run of tool calls and prose, closed by one result.
    private func session(count: Int, turn: Int) -> [MessageKind] {
        (0..<count).map { $0 % turn == turn - 1 ? .result : .toolUse }
    }

    @Test("a session short enough to draw whole is drawn whole")
    func shortSessionIsWhole() {
        #expect(TranscriptTail.start(in: session(count: 0, turn: 5)) == 0)
        #expect(TranscriptTail.start(in: session(count: 1, turn: 5)) == 0)
        #expect(TranscriptTail.start(in: session(count: 80, turn: 5)) == 0)
    }

    @Test("a session one row past the tail length gives up exactly that row")
    func oneRowPastTheLength() {
        // 81 rows, turns of ten, so the cut lands at 1 and row 0 is not the end of a turn.
        #expect(TranscriptTail.start(in: session(count: 81, turn: 10)) == 1)
    }

    @Test("a long session starts on a turn boundary at or above the cut")
    func longSessionStartsOnATurnBoundary() {
        let kinds = session(count: 4_000, turn: 30)
        let start = TranscriptTail.start(in: kinds)

        #expect(start <= 4_000 - TranscriptTail.length)
        #expect(kinds[start - 1] == .result)
    }

    @Test("the tail never holds fewer rows than it was asked for")
    func neverShorterThanTheLength() {
        for turn in [2, 7, 30, 61, 200] {
            let kinds = session(count: 1_000, turn: turn)
            let start = TranscriptTail.start(in: kinds)
            #expect(kinds.count - start >= TranscriptTail.length)
        }
    }

    @Test("a turn longer than the tail is cut rather than drawn in full")
    func aTurnLongerThanTheTailIsCut() {
        // One turn, no result row anywhere, so there is no boundary to reach for.
        let kinds = [MessageKind](repeating: .toolUse, count: 1_000)
        #expect(TranscriptTail.start(in: kinds) == 1_000 - TranscriptTail.length)
    }

    @Test("the reach above the cut is bounded by the tail length")
    func reachIsBounded() {
        var kinds = [MessageKind](repeating: .toolUse, count: 1_000)
        // The only boundary sits far above the cut, out of reach.
        kinds[100] = .result
        #expect(TranscriptTail.start(in: kinds) == 1_000 - TranscriptTail.length)
    }

    @Test("a length of zero draws everything rather than nothing")
    func zeroLengthDrawsEverything() {
        #expect(TranscriptTail.start(in: session(count: 500, turn: 10), length: 0) == 0)
    }

    /// The list asks this over `rows.lazy.map(\.kind)` rather than over an array it built, so the
    /// answer has to be the same read through a view of the rows as it is read off a copy of them.
    @Test("a lazy view of the kinds answers what an array of them does")
    func lazyKindsAgree() {
        let kinds = session(count: 500, turn: 10)
        #expect(TranscriptTail.start(in: kinds.lazy.map { $0 }) == TranscriptTail.start(in: kinds))
    }
}
