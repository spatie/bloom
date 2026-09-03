import Foundation
import Testing
@testable import BloomCore

/// The menu bar as a table: which items exist, what they are called, and which key each carries.
///
/// `BloomCommands` is a `Commands` body, which is a view, so before this table existed none of
/// those four facts could be checked by anything but opening the menus and reading them. The one
/// that bites is the last: two items claiming one keystroke is not a tie AppKit reports, it picks
/// whichever it finds first and the other never fires. That has been hit here at least twice.
@Suite("MenuBarCatalogue")
struct MenuBarCatalogueTests {
    /// Every key in the bar, paired with the item that holds it.
    private var keyed: [(MenuShortcut, MenuBarItem)] {
        MenuBarCatalogue.commands.compactMap { item in
            item.key.map { ($0, item) }
        }
    }

    @Test("every action has exactly one row, so a lookup cannot trap")
    func everyActionHasARow() {
        for action in MenuBarAction.allCases {
            #expect(MenuBarCatalogue[action].action == action, "\(action)")
        }
        #expect(MenuBarCatalogue.commands.count == MenuBarAction.allCases.count)
    }

    /// The bug this table was written for. Two items on one keystroke, anywhere in the bar, is a
    /// silent loss of whichever AppKit looks at second.
    @Test("no two items in the whole bar claim the same keystroke")
    func noCollisions() {
        var seen: [MenuShortcut: MenuBarAction] = [:]
        for (key, item) in keyed {
            if let other = seen[key] {
                Issue.record("\(item.action) and \(other) both claim \(key)")
            }
            seen[key] = item.action
        }
    }

    /// Every key in this app is a Command key. A menu item bound to a bare letter would eat that
    /// letter out of every text field in the window.
    @Test("every key equivalent carries Command")
    func everyKeyIsACommandKey() {
        for (key, item) in keyed {
            #expect(key.modifiers.contains(.command), "\(item.action)")
        }
    }

    @Test("every item is in a menu that exists and says something")
    func everyItemIsNamed() {
        for item in MenuBarCatalogue.commands {
            #expect(!item.title.isEmpty, "\(item.action)")
            #expect(item.title.trimmingCharacters(in: .whitespaces) == item.title, "\(item.action)")
            #expect(MenuBarCatalogue.items(in: item.menu).contains(item), "\(item.action)")
        }
    }

    /// Every menu Bloom claims to fill has something in it. An empty menu title in the bar is a
    /// word with nothing under it.
    @Test("no menu is empty")
    func noEmptyMenu() {
        for menu in MenuBarMenu.allCases {
            #expect(!MenuBarCatalogue.items(in: menu).isEmpty, "\(menu)")
        }
    }

    /// One door into the project list, where there were two. New Project and Add Project Folder
    /// both ended in a project in the sidebar, so the pair asked which kind of person you were
    /// before you had said anything; the target decides the verb now. The sidebar's `+` draws this
    /// same title rather than a second spelling of it.
    @Test("there is one way to get a project, it is in File, and it carries a key")
    func oneProjectDoorInTheBar() {
        let start = MenuBarCatalogue[.startProject]
        #expect(start.menu == .file)
        #expect(start.key != nil)
        // It does not depend on a project existing, since it is how the first one arrives.
        #expect(start.availability == .always)
        // The retired key is not quietly reused: shift-command-O was Add Project Folder and now
        // belongs to nothing, which is what lets it come back if a second act ever earns one.
        #expect(!MenuBarCatalogue.commands.contains(where: { $0.title.contains("Add Project") }))
    }

    /// The two splits are the only items whose key lives on a submenu row, because they are the
    /// only submenus with a "same again" row for it to sit on. Anything else marked this way would
    /// be a key drawn beside an item AppKit never fires.
    @Test("only the two splits put their key on a submenu row")
    func onlyTheSplitsDeferTheirKey() {
        let deferred = MenuBarCatalogue.commands.filter(\.keyOnSameAgainRow).map(\.action)
        #expect(Set(deferred) == [.splitRight, .splitDown])
        for action in deferred {
            #expect(MenuBarCatalogue[action].key != nil, "\(action)")
        }
    }

    /// A two-state item is one row that changes its label. Both labels have to be there, or the
    /// item says "Pin" on a workspace that is already pinned.
    @Test("a two-state item carries both of its titles")
    func twoStateItems() {
        let twoState = MenuBarCatalogue.commands.filter { $0.alternateTitle != nil }
        #expect(Set(twoState.map(\.action)) == [.pin, .unreadMark])
        for item in twoState {
            #expect(item.title(alternate: false) == item.title, "\(item.action)")
            #expect(item.title(alternate: true) == item.alternateTitle, "\(item.action)")
        }
        // An item with one title answers the same way whichever state it is asked about, so a
        // caller cannot get an empty row by asking the wrong question.
        #expect(MenuBarCatalogue[.archive].title(alternate: true) == "Archive Workspace")
    }

    // MARK: - One action, one name

    /// The rule the whole sweep turns on: an item in the bar and the context menu offering the
    /// same thing say the same words, or the two teach different names for one action.
    @Test("the bar words a workspace's actions the way its own row menu does")
    func workspaceWording() {
        #expect(MenuBarCatalogue[.openInEditor].title == "Open in Editor")
        #expect(MenuBarCatalogue[.revealInFinder].title == "Reveal in Finder")
        #expect(MenuBarCatalogue[.copyBranchName].title == "Copy Branch Name")
        #expect(MenuBarCatalogue[.copyName].title == "Copy Name")
        #expect(MenuBarCatalogue[.renameWorkspace].title == "Rename")
        #expect(MenuBarCatalogue[.colour].title == "Colour")
        #expect(MenuBarCatalogue[.pin].title == "Pin")
        #expect(MenuBarCatalogue[.pin].alternateTitle == "Unpin")
    }

    /// The unread mark's two labels are `WorkspaceUnreadMark`'s, because a workspace row offers
    /// the same item and the two must not disagree about one workspace.
    @Test("the unread item is worded by the rule the rows already read")
    func unreadWording() {
        let item = MenuBarCatalogue[.unreadMark]
        #expect(item.title == UnreadMarkAction.markUnread.title)
        #expect(item.alternateTitle == UnreadMarkAction.markRead.title)
    }

    /// Split Right and Split Down are worded the same in the bar, in a pane's own menu and in the
    /// AppKit menu a terminal returns, which is what makes one gesture out of three surfaces.
    @Test("the splits are worded as the pane menus word them")
    func splitWording() {
        #expect(MenuBarCatalogue[.splitRight].title == "Split Right")
        #expect(MenuBarCatalogue[.splitDown].title == "Split Down")
        #expect(MenuBarCatalogue[.closePane].title == "Close Pane")
        #expect(MenuBarCatalogue[.zoomPane].title == "Zoom Pane")
    }

    // MARK: - Where the keys went

    /// Every key a focused view takes before the menu bar sees it, and what the bar spends it on.
    ///
    /// **A view that has first responder beats the menu bar**, measured, so a key on both sides
    /// means the menu item silently does not fire while that view has the keyboard. Some of those
    /// overlaps are deliberate: `Cmd+W` closes a pane in a shell and a tab everywhere else, and
    /// the zoom trio resolves onto the terminal either way, so the two routes agree. Two do not
    /// agree, and they are recorded here rather than quietly fixed, because changing either is a
    /// decision about muscle memory rather than about menus. See `docs/MENUS.md`.
    ///
    /// The value is what the bar draws for that key, or nil for a key the bar does not spend at
    /// all. A new overlap fails this test, which is the point of writing it out.
    @Test("every key a focused view takes is either unspent in the bar or a known overlap")
    func theKeysTheViewsOwn() {
        let claimedByViews: [MenuShortcut: MenuBarAction?] = [
            // A terminal splits a shell with these, which is iTerm's binding and Ghostty's.
            // Shift+Cmd+D is also Show Changes: in a shell it splits, everywhere else it opens the
            // review, and nothing in the app says which you are about to get.
            MenuShortcut("d", .command): nil,
            MenuShortcut("d", .command, .shift): .showChanges,
            // It clears itself with this one, which nothing in the bar claims and no menu shows.
            MenuShortcut("k", .command): nil,
            // Deliberate: the pane in a shell, the tab everywhere else.
            MenuShortcut("w", .command): .closeTab,
            // Deliberate: the same action reached two ways.
            MenuShortcut(.return, .command, .shift): .zoomPane,
            // A terminal steps pane focus with all four arrows. Two of them are also how you move
            // between workspaces, and the terminal wins without saying so.
            MenuShortcut(.leftArrow, .command, .option): nil,
            MenuShortcut(.rightArrow, .command, .option): nil,
            MenuShortcut(.upArrow, .command, .option): .previousWorkspace,
            MenuShortcut(.downArrow, .command, .option): .nextWorkspace,
            // Deliberate: `TextZoom` walks up from first responder, so the menu and the terminal
            // grow the same shell.
            MenuShortcut("+", .command): .zoomIn,
            MenuShortcut("-", .command): .zoomOut,
            MenuShortcut("0", .command): .actualSize,
            // A browser page finds in itself with the same three the Edit menu draws, which is the
            // same action arriving by a shorter route.
            MenuShortcut("f", .command): .find,
            MenuShortcut("g", .command): .findNext,
            MenuShortcut("g", .command, .shift): .findPrevious
        ]

        let inTheBar = Dictionary(uniqueKeysWithValues: keyed.map { ($0.0, $0.1.action) })
        for (key, expected) in claimedByViews {
            #expect(inTheBar[key] == expected, "\(key) is drawn as \(String(describing: inTheBar[key]))")
        }
    }

    /// `Cmd+\` and `Shift+Cmd+\` are the editor split, `Cmd+D` and `Shift+Cmd+D` are the shell
    /// split, and that allocation is the reason the two never fight.
    @Test("the splits keep the editor's key rather than the shell's")
    func theSplitsKeepTheirKey() {
        #expect(MenuBarCatalogue[.splitRight].key == MenuShortcut("\\", .command))
        #expect(MenuBarCatalogue[.splitDown].key == MenuShortcut("\\", .command, .shift))
    }

    /// The items added by the sweep that deliberately carry no key. A key is worth having for
    /// something done often; a row with no key still teaches that the action exists.
    @Test("the once-in-a-workspace items take no key")
    func theItemsWithNoKey() {
        for action in [MenuBarAction.pin, .unreadMark, .colour, .copyName, .renameTab, .focusPane] {
            #expect(MenuBarCatalogue[action].key == nil, "\(action)")
        }
    }

    /// Merging is the most consequential thing a person can ask Bloom to do to a branch, it
    /// happens once per workspace, and it is the one item in the bar whose press is not undone by
    /// pressing it again. A keystroke there buys a slip.
    @Test("merging is an item and not a keystroke")
    func mergeTakesNoKey() {
        let item = MenuBarCatalogue[.merge]
        #expect(item.menu == .workspace)
        #expect(item.key == nil)
        // The greyed wording. When the band is on screen the item says which merge, off
        // `GitHub.MergeMethod.buttonLabel`, which is also what the split button says.
        #expect(item.title == "Merge")
    }

    /// Merge sits directly above Archive, because those two are the ends of a workspace's life and
    /// that is the order they happen in. Said as a test because a table is a list and an insert in
    /// the wrong place is invisible in a diff.
    @Test("merging is read directly above archiving")
    func mergeSitsAboveArchive() {
        let workspace = MenuBarCatalogue.items(in: .workspace).map(\.action)
        guard let merge = workspace.firstIndex(of: .merge),
              let archive = workspace.firstIndex(of: .archive) else {
            Issue.record("the Workspace menu is missing one of the two")
            return
        }
        #expect(archive == merge + 1)
    }
}
