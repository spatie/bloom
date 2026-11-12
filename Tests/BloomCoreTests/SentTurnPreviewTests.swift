import Testing
@testable import BloomCore

@Suite("Sent turn preview")
struct SentTurnPreviewTests {
    /// Small limits, so each case reads at a glance and none depends on the tuned stages.
    private let small = SentTurnPreview.Stage(lines: 3, bytes: 40)

    @Test("a message that fits is drawn whole")
    func shortIsWhole() {
        #expect(SentTurnPreview.cut("Peux-tu regarder ?\n\nMerci", stage: 0) == nil)
        #expect(SentTurnPreview.cut("", stage: 0) == nil)
    }

    @Test("a message at both limits exactly is drawn whole, final line break included")
    func atLimitsIsWhole() {
        #expect(SentTurnPreview.cut("a\nb\nc", within: small) == nil)
        #expect(SentTurnPreview.cut("a\nb\nc\n", within: small) == nil)
        #expect(SentTurnPreview.cut(String(repeating: "a", count: 40), within: small) == nil)
    }

    @Test("a pasted log keeps its first lines")
    func longLogKeepsFirstLines() {
        #expect(SentTurnPreview.cut("a\nb\nc\nd\ne", within: small) == "a\nb\nc…")
    }

    @Test("a base64 image on one line keeps its first bytes")
    func oneLongLineKeepsFirstBytes() {
        let cut = SentTurnPreview.cut(String(repeating: "QUJD", count: 60_000), within: small)
        #expect(cut == String(repeating: "QUJD", count: 10) + SentTurnPreview.ellipsis)
    }

    @Test("Windows line endings count as lines and leave no carriage return behind")
    func carriageReturnsCount() {
        #expect(SentTurnPreview.cut("a\r\nb\r\nc\r\nd", within: small) == "a\r\nb\r\nc…")
    }

    @Test("a cut never falls inside a character")
    func cutKeepsCharactersWhole() {
        // Limits that fall inside the accent of the 14th decomposed é (3 bytes) and inside the second
        // half of the 6th flag (8 bytes): rounding to a scalar alone would leave a bare e or half a flag.
        let decomposed = "e\u{301}"
        let accents = SentTurnPreview.cut(String(repeating: decomposed, count: 100), within: .init(lines: 3, bytes: 41))
        #expect(accents == String(repeating: decomposed, count: 13) + SentTurnPreview.ellipsis)
        let flags = SentTurnPreview.cut(String(repeating: "🇧🇪", count: 30), within: .init(lines: 3, bytes: 45))
        #expect(flags == String(repeating: "🇧🇪", count: 5) + SentTurnPreview.ellipsis)
    }

    @Test("each stage shows more, and the last one is the whole message")
    func stagesGrow() {
        let log = (1...5_000).map { "line \($0)" }.joined(separator: "\n")
        let first = SentTurnPreview.cut(log, stage: 0)
        let second = SentTurnPreview.cut(log, stage: 1)
        #expect(first?.split(separator: "\n").count == SentTurnPreview.stages[0].lines)
        #expect(second?.split(separator: "\n").count == SentTurnPreview.stages[1].lines)
        #expect(SentTurnPreview.cut(log, stage: SentTurnPreview.stages.count) == nil)
    }

    @Test("a merge turn keeps its instructions whole, so they are still drawn as a chip")
    func mergeTurnIsWhole() {
        let limits = SentTurnPreview.Stage(lines: 100, bytes: 200)
        let turn = "Merge #42.\n\n\(MergeInstructions.canonical)"
        #expect(turn.utf8.count > limits.bytes)
        #expect(SentTurnPreview.cut(turn, within: limits) == nil)
    }

    @Test("a paste before Bloom's instructions is cut, and the instructions go with the rest")
    func pasteBeforeInstructionsIsCut() {
        let paste = String(repeating: "QUJD", count: 5_000)
        let cut = SentTurnPreview.cut(paste + "\n\n" + MergeInstructions.canonical, within: small)
        #expect(cut == String(paste.prefix(40)) + SentTurnPreview.ellipsis)
    }
}
