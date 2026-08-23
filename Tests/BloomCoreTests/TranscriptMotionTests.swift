import Testing
import Foundation
@testable import BloomCore

@Suite("What the transcript animates")
struct TranscriptMotionTests {
    @Test("a row that lands where something else was fades in")
    func rowsThatFade() {
        #expect(TranscriptMotion.fadesOnArrival(.toolUse))
        #expect(TranscriptMotion.fadesOnArrival(.toolResult))
        #expect(TranscriptMotion.fadesOnArrival(.permissionAsk))
        #expect(TranscriptMotion.fadesOnArrival(.result))
        #expect(TranscriptMotion.fadesOnArrival(.error))
        #expect(TranscriptMotion.fadesOnArrival(.system))
        #expect(TranscriptMotion.fadesOnArrival(.notice))
    }

    /// All three are already on screen when the stored row lands, drawn by something lined up
    /// column for column with it. A fade would take what the reader is looking at away and bring
    /// it back.
    @Test("a row that replaces something already drawn does not")
    func rowsThatDoNotFade() {
        #expect(!TranscriptMotion.fadesOnArrival(.assistantText))
        #expect(!TranscriptMotion.fadesOnArrival(.thinking))
        #expect(!TranscriptMotion.fadesOnArrival(.user))
    }
}
