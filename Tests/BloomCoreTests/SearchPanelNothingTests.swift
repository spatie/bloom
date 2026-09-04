import Foundation
import Testing
@testable import BloomCore

/// What the card says when it has no rows, and one property that holds over all of it.
@Suite("Search panel nothing")
struct SearchPanelNothingTests {
    /// Every sentence the card can draw, so a case added without a thought fails the property
    /// below rather than passing by not being listed.
    private static let all: [SearchPanelNothing] = [
        .nothingYet,
        .noMatch("houdini"),
        .noLiveMatch("houdini", archived: 1),
        .noLiveMatch("houdini", archived: 12),
        .noHiddenMatch("houdini", hidden: 1),
        .noHiddenMatch("houdini", hidden: 13),
        .noCommand("houdini"),
    ]

    /// Whether a line break could part a number from the word it counts.
    ///
    /// **This asks the question rather than matching the answer.** Asserting that a message
    /// contains "13\u{00A0}hidden" would prove only that the string is the one that was typed; a
    /// fourth sentence with a count in it would pass by not being mentioned. So this walks the
    /// characters and refuses any digit followed by a breaking space, whatever the sentence is.
    private func partsACount(_ message: String) -> Bool {
        let characters = Array(message)
        for (index, character) in characters.enumerated() where character.isNumber {
            guard index + 1 < characters.count else { continue }
            let next = characters[index + 1]
            guard next.isWhitespace else { continue }
            if next != "\u{00A0}" { return true }
        }
        return false
    }

    /// The card wraps, and at the width the panel is drawn at the hidden sentence broke after the
    /// number: "…matches “houdini”. 13" with "hidden projects are left out." on the next line.
    @Test("no count on the card can be parted from its noun by a line break")
    func countsAreTiedToTheirNouns() {
        for nothing in Self.all {
            #expect(!partsACount(nothing.message), "\(nothing.message)")
        }
    }

    /// The property is worth nothing if it cannot fail, so this is the same walk over a sentence
    /// written the wrong way.
    @Test("an ordinary space after a count is what this catches")
    func theCheckCanFail() {
        #expect(partsACount("13 hidden projects are left out."))
        #expect(!partsACount("13\u{00A0}hidden projects are left out."))
    }

    /// Three different facts, three different sentences, and a reader should not be able to tell
    /// which case they are looking at from the tone.
    @Test("every case says something, and no two say the same thing")
    func eachCaseSaysItsOwnThing() {
        let messages = Self.all.map(\.message)
        #expect(messages.allSatisfy { !$0.isEmpty })
        #expect(Set(messages).count == messages.count)
        #expect(Self.all.allSatisfy { !$0.title.isEmpty })
    }

    /// The query is the useful part, so it survives into every sentence that is about one.
    @Test("a sentence about a query quotes it")
    func theQueryIsQuoted() {
        let aboutAQuery: [SearchPanelNothing] = [
            .noMatch("houdini"),
            .noLiveMatch("houdini", archived: 12),
            .noHiddenMatch("houdini", hidden: 13),
            .noCommand("houdini"),
        ]
        for nothing in aboutAQuery {
            #expect(nothing.message.contains("\u{201C}houdini\u{201D}"), "\(nothing.message)")
        }
    }
}
