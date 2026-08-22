import Testing
import Foundation
@testable import BloomCore

/// Which completion menu a draft asks for, and where that menu is allowed to open.
///
/// These rules spent their first months inside the app target, where this suite could not see
/// them and `SlashCommandTests` kept a hand copied duplicate of `slashQuery` honest by eye. They
/// were moved into the core when the create sheet joined the transcript as a second caller: two
/// composers resolving menus through an untested function is how the two drift.
@Suite("Composer menu resolution")
struct ComposerMenuTests {

    // MARK: - The slash token

    @Test("a lone /word opens the slash menu with the word as the query")
    func slashOpens() {
        #expect(ComposerMenu.resolve(draft: "/", caret: 1) == .slash(""))
        #expect(ComposerMenu.resolve(draft: "/re", caret: 3) == .slash("re"))
        #expect(ComposerMenu.slashQuery(in: "/review-pr") == "review-pr")
    }

    @Test("a space, a newline or a tab after the word closes the slash menu")
    func slashClosesOnWhitespace() {
        #expect(ComposerMenu.slashQuery(in: "/review ") == nil)
        #expect(ComposerMenu.slashQuery(in: "/review the diff") == nil)
        #expect(ComposerMenu.slashQuery(in: "/re\nview") == nil)
        #expect(ComposerMenu.slashQuery(in: "/re\tview") == nil)
    }

    @Test("a draft that does not lead with a slash never opens the slash menu")
    func slashNeedsTheLeadingSlash() {
        #expect(ComposerMenu.slashQuery(in: "") == nil)
        #expect(ComposerMenu.slashQuery(in: "review") == nil)
        #expect(ComposerMenu.slashQuery(in: "run /review") == nil)
    }

    // MARK: - The mention token

    @Test("an @ at the caret opens the mention menu with what follows it as the query")
    func mentionOpens() throws {
        let token = try #require(ComposerMenu.resolve(draft: "fix @Sources", caret: 12).mention)
        #expect(token.start == 4)
        #expect(token.length == 8)
        #expect(token.query == "Sources")
    }

    @Test("the token is measured in UTF-16 units, the unit the text view reports its caret in")
    func mentionMeasuresUTF16() throws {
        let draft = "🙂 @Sou"
        let caret = (draft as NSString).length
        let token = try #require(ComposerMenu.resolve(draft: draft, caret: caret).mention)
        #expect(token.start == 3)
        #expect(token.length == caret - 3)
        #expect(token.query == "Sou")
    }

    @Test("an @ in the middle of a word is an email address, not a mention")
    func mentionNeedsABoundary() {
        #expect(ComposerMenu.resolve(draft: "freek@spatie", caret: 12) == .none)
        #expect(ComposerMenu.resolve(draft: "(@Sources", caret: 9).mention != nil)
        #expect(ComposerMenu.resolve(draft: "[@Sources", caret: 9).mention != nil)
    }

    @Test("whitespace between the @ and the caret closes the mention menu")
    func mentionClosesOnWhitespace() {
        #expect(ComposerMenu.resolve(draft: "@Sources done", caret: 13) == .none)
        #expect(ComposerMenu.resolve(draft: "@Sources\n", caret: 9) == .none)
    }

    @Test("the slash menu outranks a mention in the same draft")
    func slashOutranksMention() {
        #expect(ComposerMenu.resolve(draft: "/re@view", caret: 8).kind == .slash)
    }

    @Test("kind tells the same menu with a longer query apart from a different menu")
    func kindIgnoresTheQuery() {
        #expect(ComposerMenu.resolve(draft: "/r", caret: 2).kind
            == ComposerMenu.resolve(draft: "/re", caret: 3).kind)
        #expect(ComposerMenu.resolve(draft: "/re", caret: 3).kind
            != ComposerMenu.resolve(draft: "@re", caret: 3).kind)
    }
}

/// Where a completion menu opens, decided from the room each side of the composer actually has.
@Suite("Menu placement")
struct MenuPlacementTests {

    @Test("a composer with a transcript above it keeps its menu above the box")
    func aboveWhenRoomy() {
        let placement = MenuLayout.placement(above: 600, below: 0)
        #expect(placement == .above(room: 600))
        #expect(placement.menuHeight == MenuLayout.maxHeight)
    }

    @Test("the create sheet's shape flips the menu below the line being typed")
    func belowWhenTheSheetIsCramped() {
        // Near enough the sheet's real numbers: seventy points of header above the box, a five
        // line editor and a status row below.
        let placement = MenuLayout.placement(above: 70, below: 170)
        #expect(placement == .below(room: 170))
        #expect(placement.menuHeight == 170)
    }

    @Test("above wins a tie, because flipping for no gain is motion nobody asked for")
    func aboveWinsWhenBelowIsNoBetter() {
        #expect(MenuLayout.placement(above: 70, below: 70) == .above(room: 70))
        #expect(MenuLayout.placement(above: 70, below: 40) == .above(room: 70))
    }

    @Test("enough room above stays above even when below has more")
    func aboveWinsWhenUseful() {
        let placement = MenuLayout.placement(above: MenuLayout.minimumHeight, below: 500)
        #expect(placement == .above(room: MenuLayout.minimumHeight))
    }

    @Test("the menu height never exceeds the cap, whichever side it opens on")
    func menuHeightIsCapped() {
        #expect(MenuLayout.placement(above: 20, below: 900).menuHeight == MenuLayout.maxHeight)
        #expect(MenuLayout.Placement.above(room: 10_000).menuHeight == MenuLayout.maxHeight)
    }

    @Test("negative room is clamped rather than trusted, because geometry arrives mid layout")
    func negativeRoomIsClamped() {
        #expect(MenuLayout.placement(above: -20, below: -20) == .above(room: 0))
        #expect(MenuLayout.placement(above: -20, below: 170) == .below(room: 170))
    }

    @Test("an unmeasured window resolves to the placement every composer had before the choice")
    func infinityMeansAbove() {
        // The window probe reports a tick after first layout, and until it does the room below
        // is computed from an infinite height. That must not flip anything.
        let placement = MenuLayout.placement(above: 600, below: .infinity)
        #expect(placement == .above(room: 600))
    }
}
