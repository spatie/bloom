import Foundation
import Testing
@testable import BloomCore

/// The command half of the panel: the menu bar table ranked, grouped by menu, and the key each row
/// prints.
///
/// Everything here is read off `MenuBarCatalogue` rather than written beside it, which is the rule
/// the feature rests on: there is no command in the panel that is not also in a menu.
@Suite("Search panel commands")
struct SearchPanelCommandsTests {
    /// Nothing typed yet, which is the state the moment `>` is pressed: the whole bar, in the
    /// order the menus draw it.
    @Test("an empty query is the whole catalogue in table order")
    func anEmptyQueryIsTheWholeBar() {
        let ranked = SearchPanelCommands.rank("")
        #expect(ranked.count == MenuBarCatalogue.commands.count)
        #expect(ranked.map(\.item.action) == MenuBarCatalogue.commands.map(\.action))
    }

    @Test("a query ranks by the same subsequence score the slash menu uses, and reports the hits")
    func rankingAndHighlights() {
        let ranked = SearchPanelCommands.rank("archive")
        #expect(ranked.first?.item.action == .archive)
        #expect(ranked.first?.highlights == [0, 1, 2, 3, 4, 5, 6])
        #expect(!ranked.contains { $0.item.action == .about })
    }

    /// The palette should teach where a thing is rather than replace the place it is.
    @Test("rows are grouped by the menu they live in, in the bar's own order")
    func groupedByMenu() {
        let sections = SearchPanelCommands.sections(SearchPanelCommands.rank(""))
        #expect(sections.map(\.title) == ["Bloom", "File", "Edit", "View", "Workspace", "Help"])
        #expect(sections.allSatisfy { $0.rows.allSatisfy { $0.drillable == nil } })
    }

    /// A section that reordered itself back to the menu's order would put the best match under two
    /// worse ones and the reader would have to read all three.
    @Test("within a menu the rows keep the ranked order")
    func rankedInsideASection() {
        let sections = SearchPanelCommands.sections(SearchPanelCommands.rank("tab"))
        guard let view = sections.first(where: { $0.title == "View" }) else {
            Issue.record("expected a View section")
            return
        }
        let scores = view.rows.compactMap { row -> Int? in
            guard case .command(let hit) = row else { return nil }
            return hit.score
        }
        #expect(scores == scores.sorted(by: >))
    }

    @Test("a menu with nothing in it is not a heading over nothing")
    func emptyMenusAreDropped() {
        let sections = SearchPanelCommands.sections(SearchPanelCommands.rank("postcard"))
        #expect(sections.map(\.title) == ["Help"])
    }

    /// Nineteen items in the bar carry no shortcut at all, and a blank slot says nothing about
    /// which of the two a row is.
    @Test("a row prints its key, or the words no key")
    func everyRowPrintsAKey() {
        #expect(MenuBarCatalogue[.archive].keyText == "\u{2318}\u{232B}")
        #expect(MenuBarCatalogue[.merge].keyText == "no key")
        #expect(MenuBarCatalogue[.nextChangedFile].keyText == "\u{2325}\u{2318}J")
        #expect(MenuBarCatalogue[.projectSettings].keyText == "\u{21E7}\u{2318},")
        #expect(MenuBarCatalogue[.zoomPane].keyText == "\u{21E7}\u{2318}\u{21A9}")
        #expect(MenuBarCatalogue[.nextWorkspace].keyText == "\u{2325}\u{2318}\u{2193}")
        #expect(MenuBarCatalogue[.closePane].keyText == "\u{2303}\u{2318}W")
    }

    /// Control, Option, Shift, Command, which is the order in every menu on the platform and not
    /// the order the `OptionSet` happens to be declared in.
    @Test("the modifiers are drawn in the platform's order")
    func modifierOrder() {
        let all = MenuShortcut("x", .command, .shift, .option, .control)
        #expect(all.display == "\u{2303}\u{2325}\u{21E7}\u{2318}X")
    }

    /// The one key the panel opens on has to be in the bar, or the panel would be a surface with a
    /// keystroke and no map.
    @Test("the panel itself is a menu item, on a key nothing else claims")
    func thePanelIsInTheBar() {
        let item = MenuBarCatalogue[.quickSearch]
        #expect(item.menu == .edit)
        #expect(item.key == .command("k"))
        let others = MenuBarCatalogue.commands.filter { $0.action != .quickSearch }
        #expect(!others.contains { $0.key == .command("k") })
    }
}
