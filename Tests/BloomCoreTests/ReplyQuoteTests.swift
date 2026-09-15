import Testing
import Foundation
@testable import BloomCore

@Suite("Reply quote")
struct ReplyQuoteTests {
    @Test("An empty draft becomes the quote and a blank line under it")
    func intoEmpty() {
        #expect(ReplyQuote.appending("Use a lock here.", to: "") == "> Use a lock here.\n\n")
    }

    @Test("A draft with words in it keeps them, a blank line above the quote")
    func afterDraft() {
        #expect(ReplyQuote.appending("second", to: "About this:  \n") == "About this:\n\n> second\n\n")
    }

    @Test("Paragraphs stay one quote, and blank edges of the selection go")
    func paragraphs() {
        #expect(ReplyQuote.appending("\none\n\ntwo\n  ", to: "") == "> one\n>\n> two\n\n")
    }

    @Test("Nothing selected, nothing to quote")
    func emptySelection() {
        #expect(ReplyQuote.appending(" \n ", to: "draft") == nil)
    }
}
