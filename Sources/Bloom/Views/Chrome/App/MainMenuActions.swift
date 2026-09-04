import AppKit
import BloomCore

/// Running a menu bar item from somewhere that is not the menu bar, and asking which of them could
/// be run at all.
///
/// **The search panel presses the app's own menu rather than carrying a second copy of every
/// action.** `BloomCommands` is a `Commands` body holding fifty-eight closures, each reaching state
/// only that body can see: a focused value, an `openWindow` bound to a scene, an `@Observable` read
/// for the greying. Handing all of that to a second caller would mean lifting every one of those
/// closures out of the view they are declared in, and the copy left behind would be free to drift.
/// Sending the real item is the same press the user would make with the pointer, so there is
/// exactly one implementation and no way for the panel to offer something the menu does not.
///
/// It answers the greying for free too. `MenuBarCatalogue.availability` says what KIND of thing has
/// to be true and deliberately holds no rule; the live answer is `NSMenuItem.isEnabled` after the
/// menu has been `update()`d, which is exactly what a person sees when they open the menu.
/// `MenuActionProbe` measured that this works with the menu never opened, which is the state the
/// panel is in.
///
/// **Matched by title, because a SwiftUI `Commands` body publishes no identifier onto the items it
/// makes.** The titles come from `MenuBarCatalogue` on both sides, so the only way a lookup can
/// miss is an item drawn under a title the table does not know, which is what `MenuCommand` exists
/// to make impossible.
@MainActor
enum MainMenuActions {
    /// Every item the bar will actually fire right now.
    ///
    /// One walk of the six menus rather than one per row: the panel asks this once when its list
    /// changes, and asking per row would `update()` each menu fifty-eight times inside a draw pass.
    ///
    /// **An item with a submenu is not in the set, and that is a fact rather than a policy.**
    /// AppKit never fires the action of an item that has one, so Split Right, Go to Tab, Focus
    /// Pane, Colour and Run open a list in the menu bar and have nothing to send here. They stay
    /// in the panel, greyed, with the reason on the row, because a list that hides what it cannot
    /// do teaches nothing. That is the rule the menu bar itself keeps.
    static func runnable() -> Set<MenuBarAction> {
        var byTitle: [String: MenuBarAction] = [:]
        for row in MenuBarCatalogue.commands {
            byTitle[row.title] = row.action
            if let alternate = row.alternateTitle { byTitle[alternate] = row.action }
        }

        var found: Set<MenuBarAction> = []
        for top in NSApp.mainMenu?.items ?? [] {
            guard let submenu = top.submenu else { continue }
            submenu.update()
            for item in submenu.items {
                guard let action = byTitle[item.title], item.isEnabled, !item.hasSubmenu else {
                    continue
                }
                found.insert(action)
            }
        }
        return found
    }

    /// Presses one item.
    ///
    /// - Returns: false when the bar carries no such item, when it is greyed, or when it is a
    ///   submenu, so a caller can say nothing happened rather than pretending something did.
    @discardableResult
    static func perform(_ action: MenuBarAction) -> Bool {
        guard let found = item(for: action) else { return false }
        let item = found.menu.items[found.index]
        guard item.isEnabled, !item.hasSubmenu else { return false }
        found.menu.performActionForItem(at: found.index)
        return true
    }

    /// Both titles are tried, because a two-state item wears whichever half its state calls for:
    /// Pin is "Unpin" on a pinned workspace, and the table knows both spellings.
    private static func item(for action: MenuBarAction) -> (menu: NSMenu, index: Int)? {
        let row = MenuBarCatalogue[action]
        let titles = [row.title, row.alternateTitle].compactMap { $0 }
        for top in NSApp.mainMenu?.items ?? [] {
            guard let submenu = top.submenu else { continue }
            submenu.update()
            if let index = submenu.items.firstIndex(where: { titles.contains($0.title) }) {
                return (submenu, index)
            }
        }
        return nil
    }
}
