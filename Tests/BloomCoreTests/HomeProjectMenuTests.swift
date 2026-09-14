import Foundation
import Testing
@testable import BloomCore

/// Home's project menu, which is scanned for a name rather than read by position.
@Suite("Home project menu")
struct HomeProjectMenuTests {
    private func repo(_ name: String, order: Int, hidden: Bool = false) -> Repo {
        Repo(name: name, path: "/Users/me/dev/\(name)", sortOrder: order, hidden: hidden)
    }

    @Test("projects are alphabetical, not in the sidebar's stored order")
    func alphabetical() {
        let menu = HomeProjectMenu([
            repo("monizze", order: 0),
            repo("invade", order: 1),
            repo("laravel-pdf", order: 2),
            repo("flareapp.io", order: 3),
        ])

        #expect(menu.visible.map(\.name) == ["flareapp.io", "invade", "laravel-pdf", "monizze"])
    }

    /// A plain `<` puts every capitalised name before every lowercase one, which would sink
    /// `VicGames` to the top of a list that is otherwise all lowercase.
    @Test("case does not decide the order, and numbers sort as numbers")
    func finderOrder() {
        let menu = HomeProjectMenu([
            repo("www", order: 0),
            repo("VicGames", order: 1),
            repo("there-there", order: 2),
            repo("site10", order: 3),
            repo("site2", order: 4),
        ])

        #expect(menu.visible.map(\.name) == ["site2", "site10", "there-there", "VicGames", "www"])
    }

    @Test("hidden projects come after the visible ones, each group alphabetical")
    func hiddenLast() {
        let menu = HomeProjectMenu([
            repo("scotty", order: 0),
            repo("bloom", order: 1, hidden: true),
            repo("alix-backend", order: 2),
            repo("ohdear", order: 3, hidden: true),
            repo("card-service", order: 4, hidden: true),
        ])

        #expect(menu.visible.map(\.name) == ["alix-backend", "scotty"])
        #expect(menu.hidden.map(\.name) == ["bloom", "card-service", "ohdear"])
    }

    @Test("nothing hidden leaves the second group empty")
    func noneHidden() {
        let menu = HomeProjectMenu([repo("b", order: 0), repo("a", order: 1)])

        #expect(menu.visible.map(\.name) == ["a", "b"])
        #expect(menu.hidden.isEmpty)
    }
}
