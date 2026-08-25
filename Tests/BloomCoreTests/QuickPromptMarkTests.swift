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
        for kind in QuickPromptMarkKind.allCases {
            let bands = QuickPromptMarkCatalog.sections(kind)
            #expect(!bands.isEmpty, "\(kind)")
            #expect(bands.allSatisfy { !$0.choices.isEmpty }, "\(kind)")
            #expect(Set(bands.map(\.id)).count == bands.count, "\(kind)")
        }
    }

    /// The two tabs hold two kinds of thing and nothing in between: a symbol never turns up under
    /// Emojis, which is the whole reason the split is worth having.
    @Test("Each tab holds only its own kind of mark, and every mark is in one of them")
    func tabsSplitTheCatalogue() {
        let icons = QuickPromptMarkCatalog.sections(.icons).flatMap(\.choices)
        let emoji = QuickPromptMarkCatalog.sections(.emoji).flatMap(\.choices)
        #expect(icons.allSatisfy { !$0.mark.isEmoji })
        #expect(emoji.allSatisfy { $0.mark.isEmoji })
        #expect(icons.count + emoji.count == QuickPromptMarkCatalog.all.count)
        for choice in QuickPromptMarkCatalog.all {
            let tab = QuickPromptMarkCatalog.kind(of: choice.mark)
            #expect(QuickPromptMarkCatalog.sections(tab).contains { $0.choices.contains(choice) })
        }
    }

    /// The emoji tab draws no heading, because the tab is the heading. The icon tab draws one over
    /// every band.
    @Test("The icon bands are named and the emoji band is not")
    func headings() {
        #expect(QuickPromptMarkCatalog.sections(.icons).allSatisfy { $0.name != nil })
        #expect(QuickPromptMarkCatalog.sections(.emoji).allSatisfy { $0.name == nil })
        #expect(QuickPromptMarkCatalog.sections(.emoji).count == 1)
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

    /// The eighteen the inline grid offered before the picker replaced it, written out rather than
    /// derived, because the point is that this list is fixed and the catalogue is not. A prompt
    /// somebody marked two years ago has to come back marked the same way, and dropping one of
    /// these while rearranging a hundred would show up as a row quietly redrawn with the fallback.
    @Test("Every mark the grid used to offer is still offered")
    func theOldGridStillResolves() {
        let grid = [
            "text.alignleft", "envelope", "list.bullet", "pencil", "gearshape", "bolt",
            "checkmark.seal", "exclamationmark.triangle", "arrow.triangle.2.circlepath", "hammer",
            "magnifyingglass", "scissors", "book", "paintbrush", "ladybug", "shippingbox",
            "doc.richtext", "sparkles",
        ]
        for symbol in grid {
            #expect(QuickPromptMark(stored: symbol) == .symbol(symbol), "\(symbol)")
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

    @Test("An empty query is the whole of the tab")
    func emptyQuery() {
        for kind in QuickPromptMarkKind.allCases {
            #expect(QuickPromptMarkCatalog.filtered(kind, query: "  ").map(\.id)
                == QuickPromptMarkCatalog.sections(kind).map(\.id), "\(kind)")
        }
    }

    @Test("A band's own name keeps the whole band")
    func matchesTheHeading() {
        let sections = QuickPromptMarkCatalog.filtered(.icons, query: "test")
        let tests = sections.first { $0.name == "Tests and checks" }
        #expect(tests?.choices.count == QuickPromptMarkCatalog.sections(.icons)
            .first { $0.name == "Tests and checks" }?.choices.count)
    }

    @Test("A word out of a symbol's name keeps that symbol")
    func matchesTheLabel() {
        let kept = QuickPromptMarkCatalog.filtered(.icons, query: "triangle").flatMap(\.choices)
        #expect(kept.contains { $0.mark == .symbol("arrow.triangle.pull") })
        #expect(kept.allSatisfy { $0.mark.stored.contains("triangle") })
    }

    @Test("An emoji is found by the word it was given")
    func matchesEmojiKeywords() {
        let kept = QuickPromptMarkCatalog.filtered(.emoji, query: "rocket").flatMap(\.choices)
        #expect(kept.map(\.mark) == [.emoji("\u{1F680}")])
    }

    /// The field sits under the tabs and belongs to the one that is open. A query that reached
    /// into the other tab would put emoji in the icon grid and there would be no saying which tab
    /// Return was about to choose from.
    @Test("A query never reaches into the tab that is not open")
    func searchesOneTabOnly() {
        #expect(QuickPromptMarkCatalog.filtered(.icons, query: "rocket").isEmpty)
        #expect(QuickPromptMarkCatalog.filtered(.emoji, query: "triangle").isEmpty)
    }

    @Test("A query nothing carries keeps nothing")
    func matchesNothing() {
        #expect(QuickPromptMarkCatalog.filtered(.icons, query: "zzzznope").isEmpty)
        #expect(QuickPromptMarkCatalog.filtered(.emoji, query: "zzzznope").isEmpty)
    }

    // MARK: - The keyboard

    @Test("Stepping clamps at both ends rather than wrapping")
    func stepsAndClamps() {
        let sections = QuickPromptMarkCatalog.sections(.icons)
        let all = sections.flatMap(\.choices)
        #expect(QuickPromptMarkCatalog.stepped(sections, from: nil, by: 1) == all.first?.mark)
        #expect(QuickPromptMarkCatalog.stepped(sections, from: nil, by: -1) == all.last?.mark)
        #expect(QuickPromptMarkCatalog.stepped(sections, from: all[0].mark, by: 1) == all[1].mark)
        #expect(QuickPromptMarkCatalog.stepped(sections, from: all[0].mark, by: -8) == all[0].mark)
        #expect(QuickPromptMarkCatalog.stepped(sections, from: all.last?.mark, by: 8)
            == all.last?.mark)
    }

    @Test("Stepping crosses from one band into the next, because a tab is one list")
    func stepsAcrossBands() {
        let sections = QuickPromptMarkCatalog.sections(.icons)
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
        let sections = QuickPromptMarkCatalog.filtered(.icons, query: "triangle")
        #expect(QuickPromptMarkCatalog.settled(sections, after: .symbol("arrow.triangle.pull"))
            == .symbol("arrow.triangle.pull"))
        #expect(QuickPromptMarkCatalog.settled(sections, after: .symbol("bolt"))
            == sections.first?.choices.first?.mark)
        #expect(QuickPromptMarkCatalog.settled(sections, after: nil)
            == sections.first?.choices.first?.mark)
        #expect(QuickPromptMarkCatalog.settled([], after: .symbol("bolt")) == nil)
    }

    // MARK: - Rows

    @Test("A band is cut into full rows with a short one at the end")
    func cutsRows() {
        let band = QuickPromptMarkSection(
            name: "Nine", choices: (0..<9).map {
                QuickPromptMarkChoice(mark: .symbol("bolt.\($0)"), label: "\($0)")
            }
        )
        let rows = band.rows(across: 4)
        #expect(rows.map(\.choices.count) == [4, 4, 1])
        #expect(rows.flatMap(\.choices) == band.choices)
    }

    /// The row's id is what a `ScrollViewReader` is given, so two rows sharing one would scroll to
    /// whichever SwiftUI reached first.
    @Test("Every row of every band carries an id of its own")
    func rowIDsAreDistinct() {
        let rows = (QuickPromptMarkCatalog.iconSections + QuickPromptMarkCatalog.emojiSections)
            .flatMap { $0.rows(across: 7) }
        #expect(Set(rows.map(\.id)).count == rows.count)
        #expect(rows.allSatisfy { !$0.choices.isEmpty })
    }

    @Test("A band nothing is left of, and a width of nothing, are both no rows")
    func cutsNothing() {
        let band = QuickPromptMarkSection(name: nil, choices: [])
        #expect(band.rows(across: 7).isEmpty)
        #expect(QuickPromptMarkCatalog.emojiSections[0].rows(across: 0).isEmpty)
    }

    // MARK: - Throwing one away

    @Test("The question names the prompt it is about")
    func asksAboutTheNamedPrompt() {
        #expect(QuickPromptDeletion.title(for: "Ship it") == "Delete \u{201C}Ship it\u{201D}?")
        #expect(QuickPromptDeletion.title(for: "  Ship it  ") == "Delete \u{201C}Ship it\u{201D}?")
    }

    @Test("A prompt with no name of its own is still asked about")
    func asksAboutTheUnnamedPrompt() {
        #expect(QuickPromptDeletion.title(for: "") == "Delete this quick prompt?")
        #expect(QuickPromptDeletion.title(for: "   ") == "Delete this quick prompt?")
    }

    /// A prompt with no name is listed by its own first line, which runs to seventy two characters.
    /// The dialog is 260 points wide, so the title is cut rather than allowed to push the buttons
    /// off the bottom of it.
    @Test("A name longer than the dialog is cut rather than wrapped")
    func cutsALongName() {
        let long = String(repeating: "a", count: QuickPrompt.previewLength)
        let title = QuickPromptDeletion.title(for: long)
        #expect(title.contains("\u{2026}"))
        #expect(title.count < long.count)
        #expect(!title.contains(long))
    }

    @Test("The question says what is lost rather than asking whether you are sure")
    func saysWhatIsLost() {
        #expect(!QuickPromptDeletion.message.lowercased().contains("are you sure"))
        #expect(QuickPromptDeletion.message.contains("cannot be brought back"))
        #expect(QuickPromptDeletion.confirmLabel == "Delete Prompt")
    }
}
