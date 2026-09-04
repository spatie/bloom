import Foundation

/// The command half of the panel: `MenuBarCatalogue` ranked against what was typed and grouped by
/// the menu each item lives in.
///
/// **A table read rather than a list written.** Every command in the panel is already in a menu,
/// with its title, its key and its menu named in one place, so there is nothing here to keep in
/// step with the menu bar and no way to add a command that only the panel has. That is the rule
/// the whole feature rests on: the panel is a faster route, never the only one.
///
/// **Grouped by menu, because the palette should teach where a thing is rather than replace the
/// place it is.** A flat ranked list would be quicker to write and would leave the reader no
/// better at finding the item again with the pointer.
///
/// There are no aliases here, so "delete" does not find Archive Workspace. That is worth having
/// and it is a content exercise over fifty-eight items rather than a change to this file, so it is
/// deliberately left out rather than half done. `FuzzyMatch` over the titles is what there is.
public enum SearchPanelCommands {
    /// How many command rows a search of things is allowed to show before the reader is asked to
    /// type `>`.
    ///
    /// The panel's first question is "which workspace was it", and a menu bar that could take the
    /// whole list would answer a question nobody asked. Four is a hint that the commands are there
    /// and a nudge towards the prefix that shows all of them.
    public static let inlineLimit = 4

    /// Below this a search of things shows no commands at all. One letter matches most of the menu
    /// bar, and a list of fifty-eight items under two workspaces is not a hint.
    public static let inlineMinimumQueryLength = 2

    /// Every item that matched, best first.
    ///
    /// An empty query answers with the whole catalogue in table order, which is what the command
    /// mode shows the moment `>` is typed: the menus, in the order the bar draws them.
    public static func rank(_ query: String, in commands: [MenuBarItem] = MenuBarCatalogue.commands) -> [SearchPanelCommandHit] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return commands.map { SearchPanelCommandHit(item: $0) }
        }
        return commands
            .compactMap { item in
                guard let hit = FuzzyMatch.hit(item.title, query: trimmed) else { return nil }
                return SearchPanelCommandHit(item: item, highlights: hit.positions, score: hit.score)
            }
            // Stably, so two items on the same score keep the order the menu bar draws them in
            // rather than swapping about between keystrokes.
            .enumerated()
            .sorted { left, right in
                left.element.score == right.element.score
                    ? left.offset < right.offset
                    : left.element.score > right.element.score
            }
            .map(\.element)
    }

    /// The ranked hits, cut into one section per menu, in the order the menu bar draws the menus.
    ///
    /// Within a menu the rows keep the ranked order rather than the table's, because a section
    /// that reordered itself back to the menu's own order would put the best match under two worse
    /// ones and the reader would have to read all three.
    public static func sections(_ hits: [SearchPanelCommandHit]) -> [SearchPanelSection] {
        MenuBarMenu.allCases.compactMap { menu in
            let rows = hits.filter { $0.item.menu == menu }
            guard !rows.isEmpty else { return nil }
            return SearchPanelSection(
                id: "menu-\(menu.rawValue)",
                title: title(of: menu),
                rows: rows.map { SearchPanelRow.command($0) }
            )
        }
    }

    /// What the menu is called at the top of the screen, which is what the heading has to say for
    /// the row under it to teach anything.
    public static func title(of menu: MenuBarMenu) -> String {
        switch menu {
        case .bloom: "Bloom"
        case .file: "File"
        case .edit: "Edit"
        case .view: "View"
        case .workspace: "Workspace"
        case .help: "Help"
        }
    }

    /// What a row prints on its trailing edge.
    ///
    /// **"no key" is printed rather than left blank.** Nineteen items in the bar carry no shortcut
    /// at all, and a blank slot says nothing about which of the two a row is. Superhuman prints the
    /// key beside every command and says out loud that the palette exists to teach you out of
    /// itself; this is the half of that which is honest about the items it cannot teach.
    public static let noKey = "no key"
}
