import Testing
import Foundation
@testable import BloomCore

/// A selection somewhere else in the window, handed to the composer: a terminal's as an
/// attachment, an answer's as a quote.
@Suite("Terminal selection")
struct TerminalSelectionTests {
    @Test("The padding a terminal puts on every row comes off")
    func trimsRowPadding() {
        let text = TerminalSelection.text("error: nope     \n  at main.swift:3   \n")
        #expect(text == "error: nope\n  at main.swift:3\n")
    }

    @Test("Blank rows at either end go, blank rows inside stay")
    func trimsBlankEdges() {
        let text = TerminalSelection.text("\n   \nfirst\n\nsecond\n   \n")
        #expect(text == "first\n\nsecond\n")
    }

    @Test("Carriage returns are line ends")
    func carriageReturns() {
        #expect(TerminalSelection.text("a\r\nb\rc") == "a\nb\nc\n")
    }

    @Test("A selection of nothing but space is no selection")
    func emptyIsNil() {
        #expect(TerminalSelection.text("   \n \t\n") == nil)
    }

    @Test("The file is named after the tab, cleaned, and when")
    func filename() throws {
        let zone = try #require(TimeZone(identifier: "Europe/Brussels"))
        let date = Date(timeIntervalSince1970: 1_789_000_000)
        #expect(
            TerminalSelection.filename(terminal: "dev: npm/run", at: date, timeZone: zone)
                == "dev- npm-run \(PastedAttachment.timestamp(date, in: zone)).txt"
        )
        #expect(TerminalSelection.filename(terminal: " .. ", at: date, timeZone: zone).hasPrefix("Terminal "))
    }
}

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
