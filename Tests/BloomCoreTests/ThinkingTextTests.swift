import Testing
@testable import BloomCore

/// The blank lines under an expanded thinking row. See `ThinkingText`.
struct ThinkingTextTests {
    @Test func theTwoNewlinesClaudeEndsABlockWithAreNotDrawn() {
        let block = "The row is taller than its text.\nSo the padding is not the cause.\n\n"
        #expect(ThinkingText.displayed(block)
            == "The row is taller than its text.\nSo the padding is not the cause.")
    }

    @Test func blankLinesInsideTheReasoningAreKept() {
        let block = "First paragraph.\n\nSecond paragraph."
        #expect(ThinkingText.displayed(block) == block)
    }

    @Test func leadingWhitespaceGoesTooSoTheTopMatchesTheBottom() {
        #expect(ThinkingText.displayed("\n\n  Planning\n") == "Planning")
    }

    @Test func carriageReturnsAndTabsAreWhitespace() {
        #expect(ThinkingText.displayed("Done.\r\n\t \r\n") == "Done.")
    }

    @Test func aBlockOfNothingButWhitespaceDrawsNothing() {
        #expect(ThinkingText.displayed("\n \n\t").isEmpty)
        #expect(ThinkingText.displayed("").isEmpty)
    }

    @Test func textWithNothingToTrimComesBackUnchanged() {
        let block = "One line, nothing around it."
        #expect(ThinkingText.displayed(block) == block)
    }

    @Test func accentedAndWideCharactersAtTheEdgesAreNotCut() {
        #expect(ThinkingText.displayed("\ncafé 思考\n\n") == "café 思考")
    }
}
