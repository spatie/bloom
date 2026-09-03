import Testing
@testable import BloomCore

@Suite("Transcript pointer")
struct TranscriptPointerTests {
    @Test("a link gets the hand every link on the platform gets")
    func linkGetsTheHand() {
        #expect(TranscriptPointer.over(link: true, chipThatOpens: false) == .hand)
    }

    @Test("prose is an I-beam, because it is selectable text")
    func proseIsText() {
        #expect(TranscriptPointer.over(link: false, chipThatOpens: false) == .text)
    }

    @Test("a chip with a file behind it is a door too")
    func chipGetsTheHand() {
        #expect(TranscriptPointer.over(link: false, chipThatOpens: true) == .hand)
    }

    @Test("a chip standing for injected instructions promises nothing")
    func chipWithNowhereToGo() {
        // It looks like the chips either side of it and opens nothing, because the words it
        // stands for are already in the turn under the pointer.
        #expect(TranscriptPointer.over(link: false, chipThatOpens: false) == .text)
    }

    @Test("a link drawn inside a chip is still a link")
    func both() {
        #expect(TranscriptPointer.over(link: true, chipThatOpens: true) == .hand)
    }
}
