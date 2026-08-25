import Testing
import Foundation
@testable import BloomCore

/// What the string in a quick prompt's `symbol` column is read as, and what the picker offers.
///
/// The column holds two kinds of thing now, and every row written before it did holds the first
/// kind, so the classification is the whole of the compatibility story: get it wrong and a shipped
/// prompt draws as a blank box.
@Suite("Quick prompt marks")
struct QuickPromptMarkTests {
    // MARK: - What a stored string is

    @Test("A name from the picker's own list is a symbol")
    func readsSymbols() {
        #expect(QuickPromptMark(stored: "doc.richtext") == .symbol("doc.richtext"))
        #expect(QuickPromptMark(stored: "text.alignleft") == .symbol("text.alignleft"))
        #expect(QuickPromptMark(stored: "arrow.triangle.pull") == .symbol("arrow.triangle.pull"))
    }

    /// Every shape of emoji, because the classification is by the character's own properties and
    /// each of these carries them differently: one scalar drawn as an emoji by default, one made
    /// into an emoji by a variation selector, a keycap over an ASCII digit, a skin tone, a family
    /// joined with zero width joiners, and a flag made of two regional indicators.
    @Test("Anything that is one emoji is an emoji, listed or not")
    func readsEmoji() {
        let emoji = [
            "\u{1F41B}",                                  // a bug, which the picker offers
            "\u{2705}",                                   // a tick
            "\u{2699}\u{FE0F}",                           // a gear, emoji only because of FE0F
            "1\u{FE0F}\u{20E3}",                          // a keycap
            "\u{1F44D}\u{1F3FD}",                         // a thumb with a skin tone
            "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}",// a family
            "\u{1F1E7}\u{1F1EA}",                         // a flag
            "\u{1F9A6}",                                  // an otter, which it does not offer
        ]
        for mark in emoji {
            #expect(QuickPromptMark(stored: mark) == .emoji(mark), "\(mark)")
            #expect(QuickPromptMark(stored: mark).isEmoji, "\(mark)")
        }
    }

    /// The characters Unicode calls emoji that nobody else would. Each can be the base of an emoji
    /// sequence, which is why the property is set on them, and each on its own is a character in a
    /// sentence.
    @Test("A digit, a copyright sign and a bare text symbol are not emoji")
    func readsNearMisses() {
        for text in ["1", "#", "*", "\u{00A9}", "\u{2122}", "\u{203C}", "\u{2699}"] {
            #expect(QuickPromptMark(stored: text) == .fallback, "\(text)")
        }
    }

    @Test("Anything else falls back rather than drawing an empty box")
    func fallsBack() {
        #expect(QuickPromptMark(stored: "") == .fallback)
        #expect(QuickPromptMark(stored: "   ") == .fallback)
        #expect(QuickPromptMark(stored: "nothing.like.this") == .fallback)
        #expect(QuickPromptMark(stored: "Run the tests") == .fallback)
        // Two emoji is not one mark. The row draws one glyph in a sixteen point box.
        #expect(QuickPromptMark(stored: "\u{1F41B}\u{1F41B}") == .fallback)
        #expect(QuickPromptMark.fallback == .symbol(QuickPrompt.defaultSymbol))
    }

    @Test("Whitespace around a stored value is not part of it")
    func trims() {
        #expect(QuickPromptMark(stored: " doc.richtext ") == .symbol("doc.richtext"))
        #expect(QuickPromptMark(stored: "\n\u{1F41B}\n") == .emoji("\u{1F41B}"))
    }

    /// The old entry point, which the store and the seed list still go through.
    @Test("A value stored before emoji existed here still resolves")
    func resolvesStoredValues() {
        #expect(QuickPrompt.resolvedSymbol("doc.richtext") == "doc.richtext")
        #expect(QuickPrompt.resolvedSymbol("nothing.like.this") == QuickPrompt.defaultSymbol)
        #expect(QuickPrompt.resolvedSymbol("\u{1F41B}") == "\u{1F41B}")
        // The prompt Bloom ships with, which must keep the mark it was shipped with.
        let shipped = QuickPromptSeed.all.first { $0.name == "Explain changes" }
        #expect(shipped.map { QuickPrompt.resolvedSymbol($0.symbol) } == shipped?.symbol)
    }

    // MARK: - The catalogue

    @Test("Every mark on offer is distinct, and every band has something in it")
    func catalogueIsWellFormed() {
        let all = QuickPromptMarkCatalog.all
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(Set(QuickPrompt.symbols).count == QuickPrompt.symbols.count)
        #expect(QuickPrompt.symbols.count >= 60)
        #expect(QuickPromptMarkCatalog.sections.allSatisfy { !$0.choices.isEmpty })
        #expect(Set(QuickPromptMarkCatalog.sections.map(\.name)).count
            == QuickPromptMarkCatalog.sections.count)
    }

    /// The labels are what the field is matched against, so an empty one is a mark that can only
    /// be found by scrolling. Lowercased, because the query is.
    @Test("Every mark carries a lowercase label to be found by")
    func everyMarkIsSearchable() {
        for choice in QuickPromptMarkCatalog.all {
            #expect(!choice.label.isEmpty, "\(choice.id)")
            #expect(choice.label == choice.label.lowercased(), "\(choice.id)")
        }
    }

    @Test("The fallback is a mark the picker offers")
    func fallbackIsOnOffer() {
        #expect(QuickPrompt.symbols.contains(QuickPrompt.defaultSymbol))
    }

    @Test("Every mark on offer classifies back to itself")
    func offeredMarksRoundTrip() {
        for choice in QuickPromptMarkCatalog.all {
            #expect(QuickPromptMark(stored: choice.mark.stored) == choice.mark, "\(choice.id)")
        }
    }

    @Test("Both kinds are on offer, and the emoji are a curated few rather than all of them")
    func bothKindsAreOffered() {
        let emoji = QuickPromptMarkCatalog.all.filter(\.mark.isEmoji)
        #expect(emoji.count >= 30)
        #expect(emoji.count <= 80)
        #expect(QuickPrompt.symbols.count > emoji.count)
    }

    // MARK: - Searching

    @Test("An empty query is the whole catalogue")
    func emptyQuery() {
        #expect(QuickPromptMarkCatalog.filtered(query: "  ").map(\.name)
            == QuickPromptMarkCatalog.sections.map(\.name))
    }

    @Test("A band's own name keeps the whole band")
    func matchesTheHeading() {
        let sections = QuickPromptMarkCatalog.filtered(query: "test")
        let tests = sections.first { $0.name == "Tests and checks" }
        #expect(tests?.choices.count
            == QuickPromptMarkCatalog.sections.first { $0.name == "Tests and checks" }?.choices.count)
    }

    @Test("A word out of a symbol's name keeps that symbol")
    func matchesTheLabel() {
        let kept = QuickPromptMarkCatalog.filtered(query: "triangle").flatMap(\.choices)
        #expect(kept.contains { $0.mark == .symbol("arrow.triangle.pull") })
        #expect(kept.allSatisfy { $0.mark.stored.contains("triangle") })
    }

    @Test("An emoji is found by the word it was given")
    func matchesEmojiKeywords() {
        let kept = QuickPromptMarkCatalog.filtered(query: "rocket").flatMap(\.choices)
        #expect(kept.map(\.mark) == [.emoji("\u{1F680}")])
    }

    @Test("A query nothing carries keeps nothing")
    func matchesNothing() {
        #expect(QuickPromptMarkCatalog.filtered(query: "zzzznope").isEmpty)
    }

    // MARK: - The keyboard

    @Test("Stepping clamps at both ends rather than wrapping")
    func stepsAndClamps() {
        let sections = QuickPromptMarkCatalog.sections
        let all = QuickPromptMarkCatalog.all
        #expect(QuickPromptMarkCatalog.stepped(sections, from: nil, by: 1) == all.first?.mark)
        #expect(QuickPromptMarkCatalog.stepped(sections, from: nil, by: -1) == all.last?.mark)
        #expect(QuickPromptMarkCatalog.stepped(sections, from: all[0].mark, by: 1) == all[1].mark)
        #expect(QuickPromptMarkCatalog.stepped(sections, from: all[0].mark, by: -8) == all[0].mark)
        #expect(QuickPromptMarkCatalog.stepped(sections, from: all.last?.mark, by: 8)
            == all.last?.mark)
    }

    @Test("Stepping crosses from one band into the next, because it is one list")
    func stepsAcrossBands() {
        let sections = QuickPromptMarkCatalog.sections
        guard let firstBand = sections.first, let secondBand = sections.dropFirst().first else {
            Issue.record("the catalogue needs at least two bands")
            return
        }
        #expect(QuickPromptMarkCatalog.stepped(sections, from: firstBand.choices.last?.mark, by: 1)
            == secondBand.choices.first?.mark)
    }

    @Test("An empty list has nothing to step onto")
    func stepsNowhere() {
        #expect(QuickPromptMarkCatalog.stepped([], from: nil, by: 1) == nil)
        #expect(QuickPromptMarkCatalog.stepped([], from: .symbol("bolt"), by: 1) == nil)
    }

    @Test("The highlight survives a query that keeps its mark, and moves when it does not")
    func settles() {
        let sections = QuickPromptMarkCatalog.filtered(query: "triangle")
        #expect(QuickPromptMarkCatalog.settled(sections, after: .symbol("arrow.triangle.pull"))
            == .symbol("arrow.triangle.pull"))
        #expect(QuickPromptMarkCatalog.settled(sections, after: .symbol("bolt"))
            == sections.first?.choices.first?.mark)
        #expect(QuickPromptMarkCatalog.settled(sections, after: nil)
            == sections.first?.choices.first?.mark)
        #expect(QuickPromptMarkCatalog.settled([], after: .symbol("bolt")) == nil)
    }
}
