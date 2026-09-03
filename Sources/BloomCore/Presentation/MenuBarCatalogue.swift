import Foundation

/// Every item the menu bar publishes: which menu it is in, what it is called, and which key it
/// carries.
///
/// **It is the source of truth rather than a description of one.** `BloomCommands` is a
/// `Commands` body, which is a view and so is a thing no test can look at, and the four questions
/// this table answers are decisions: which items exist, what each is called, which key it carries
/// and roughly when it can be pressed. Written inside the view, all four were only checkable by
/// opening the menus and reading them. Written here, `MenuBarCatalogueTests` can hold the one that
/// actually bites, which is that no two items in the bar claim the same keystroke: two items in
/// one menu sharing a key equivalent is not a tie AppKit reports, it silently picks the one it
/// finds first. That bug has been hit here at least twice, once between Go to Home and Actual Size
/// over `Cmd+0`, and each time it was found by pressing the key rather than by a test.
///
/// **Enablement is not in the table, and that is deliberate.** Whether Split Right can be pressed
/// depends on the live pane tree, whether Stop Agent can depends on a running turn, and neither is
/// a value the core can hold. What is here is `availability`, which says what KIND of thing has to
/// be true, so a reader can see at a glance which items are always live and the app target has one
/// place to be consistent with. The rules themselves stay where the state is, and the ones already
/// extracted (`PaneSplit`, `TabClosure`, `WorkspaceMenuSubject`, `TabCycle`) are named on the
/// items that read them.
///
/// **Greyed rather than absent.** A menu bar is a map of what the app can do, so an item that
/// vanishes when it cannot be pressed teaches nothing. That is the opposite of the habit the
/// context menus have, on purpose: a context menu is a shortcut to somewhere you already are. The
/// two exceptions in the table are the run scripts and the setup script, which are absent when the
/// project defines none, because a permanently empty submenu teaches nothing either.
public enum MenuBarCatalogue {
    /// The item for one action. Traps on an action with no row, which cannot happen: `commands`
    /// covers every case and `MenuBarCatalogueTests.everyActionHasARow` holds it.
    public static subscript(_ action: MenuBarAction) -> MenuBarItem {
        guard let item = byAction[action] else {
            preconditionFailure("no menu bar row for \(action)")
        }
        return item
    }

    /// The items of one menu, in the order they are drawn.
    public static func items(in menu: MenuBarMenu) -> [MenuBarItem] {
        commands.filter { $0.menu == menu }
    }

    private static let byAction: [MenuBarAction: MenuBarItem] = Dictionary(
        uniqueKeysWithValues: commands.map { ($0.action, $0) }
    )

    // MARK: - The table

    /// Ordered by menu, and within a menu by where the item is drawn. The separators are not here:
    /// a rule between two items is a layout decision, and drawing one is the only thing the view
    /// still gets to decide for itself.
    public static let commands: [MenuBarItem] = [
        // MARK: Bloom

        MenuBarItem(.about, in: .bloom, "About Bloom"),
        MenuBarItem(.checkForUpdates, in: .bloom, "Check for Updates…", availability: .sometimes),

        // MARK: File

        MenuBarItem(.newWorkspace, in: .file, "New Workspace…", key: .command("n"), availability: .needsProject),
        MenuBarItem(.newWorkspaceFromPullRequest, in: .file, "New Workspace from Pull Request…", availability: .needsProject),
        // The conversation above every project, started again. It existed only as a toolbar button
        // that appears while Ask Bloom is open, which is a control you have to already be looking
        // at to find: the owner asked whether Bloom could clear an Ask conversation at all, and it
        // could, by pressing a glyph a few inches from where he was reading. An item here is the
        // answer to somebody looking for it in the place a Mac app keeps "start another one".
        //
        // No key equivalent. Cmd+N is New Workspace and this is the rarer of the two, so it takes
        // the item without the shortcut, which is the same call `newWorkspaceFromPullRequest`
        // makes directly above it.
        MenuBarItem(.newAskConversation, in: .file, "New Ask Bloom Conversation", availability: .always),
        MenuBarItem(.projectSettings, in: .file, "Project Settings…", key: .init("comma", .command, .shift), availability: .needsProject),
        MenuBarItem(.newSession, in: .file, "New Session", key: .command("t"), availability: .needsWorkspace),
        MenuBarItem(.newTerminalTab, in: .file, "New Terminal Tab", key: .init("t", .command, .shift), availability: .needsWorkspace),
        MenuBarItem(.newBrowserTab, in: .file, "New Browser Tab", key: .init("b", .command, .shift), availability: .needsWorkspace),
        MenuBarItem(.showChanges, in: .file, "Show Changes", key: .init("d", .command, .shift), availability: .needsWorkspace),
        MenuBarItem(.showNotes, in: .file, "Show Notes", key: .init("n", .command, .shift), availability: .needsWorkspace),
        // The rename a tab has always had on its own context menu and on its VoiceOver actions
        // rotor, and nowhere else. No key: Finder gives Rename none either, and the strip already
        // spends a double click on it.
        MenuBarItem(.renameTab, in: .file, "Rename Tab", availability: .needsTab),
        MenuBarItem(.closeTab, in: .file, "Close Tab", key: .command("w"), availability: .needsTab),
        // One item, where there were two: New Project at option-command-N and Add Project Folder
        // at shift-command-O. They were two verbs for two different people, and both of them ended
        // in a project in the sidebar, so the menu was asking which kind of person you were before
        // you had said anything. Which verb a target needs is worked out from the target now. See
        // `ProjectTargetVerdict`, and `StartProjectView` for the window it draws.
        MenuBarItem(.startProject, in: .file, "Start a Project…", key: .init("n", .command, .option)),
        MenuBarItem(.save, in: .file, "Save", key: .command("s"), availability: .sometimes),

        // MARK: Edit

        MenuBarItem(.find, in: .edit, "Find…", key: .command("f")),
        MenuBarItem(.findNext, in: .edit, "Find Next", key: .command("g")),
        MenuBarItem(.findPrevious, in: .edit, "Find Previous", key: .init("g", .command, .shift)),
        MenuBarItem(.search, in: .edit, "Search", key: .init("f", .command, .shift), availability: .needsProject),

        // MARK: View

        // The two splits are submenus of the three kinds, and the key sits on the row that means
        // "the same again" rather than on the parent. See `PaneDuplicateOutcome.sameAgainKind`.
        MenuBarItem(.splitRight, in: .view, "Split Right", key: .command("\\"), keyOnSameAgainRow: true, availability: .needsSplittablePane),
        MenuBarItem(.splitDown, in: .view, "Split Down", key: .init("\\", .command, .shift), keyOnSameAgainRow: true, availability: .needsSplittablePane),
        MenuBarItem(.closePane, in: .view, "Close Pane", key: .init("w", .command, .control), availability: .needsWorkspace),
        // Both of these are a terminal tab's, because a shell tree is the only thing in the centre
        // column that can zoom a pane or step focus between them. They were reachable from a right
        // click inside a shell and from nowhere else, so the zoom's key was written on a menu the
        // app draws and never on one a reader can browse.
        MenuBarItem(.zoomPane, in: .view, "Zoom Pane", key: .init(.return, .command, .shift), availability: .needsTerminalPane),
        MenuBarItem(.focusPane, in: .view, "Focus Pane", availability: .needsTerminalPane),
        MenuBarItem(.previousTab, in: .view, "Previous Tab", key: .init("[", .command, .shift), availability: .needsSeveralTabs),
        MenuBarItem(.nextTab, in: .view, "Next Tab", key: .init("]", .command, .shift), availability: .needsSeveralTabs),
        MenuBarItem(.goToTab, in: .view, "Go to Tab", availability: .needsTab),
        MenuBarItem(.nextChangedFile, in: .view, "Next Changed File", key: .init("j", .command, .option), availability: .needsReview),
        MenuBarItem(.previousChangedFile, in: .view, "Previous Changed File", key: .init("k", .command, .option), availability: .needsReview),
        MenuBarItem(.toggleSidebar, in: .view, "Toggle Sidebar", key: .init("s", .command, .control)),
        MenuBarItem(.toggleInspector, in: .view, "Toggle Inspector", key: .init("i", .command, .option), availability: .needsWorkspace),
        MenuBarItem(.nextWorkspace, in: .view, "Next Workspace", key: .init(.downArrow, .command, .option), availability: .needsAnyWorkspace),
        MenuBarItem(.previousWorkspace, in: .view, "Previous Workspace", key: .init(.upArrow, .command, .option), availability: .needsAnyWorkspace),
        MenuBarItem(.nextUnread, in: .view, "Next Unread", key: .init("u", .command, .shift), availability: .sometimes),
        MenuBarItem(.goToHome, in: .view, "Go to Home", key: .init("h", .command, .shift), availability: .sometimes),
        // No key. Every letter that would read as this one is taken by something in front of it,
        // and a menu item is discoverable without one where a second binding on a key the composer
        // already uses is not.
        MenuBarItem(.goToAsk, in: .view, "Go to Ask Bloom", availability: .sometimes),
        MenuBarItem(.zoomIn, in: .view, "Zoom In", key: .command("+"), availability: .sometimes),
        MenuBarItem(.zoomOut, in: .view, "Zoom Out", key: .command("-"), availability: .sometimes),
        MenuBarItem(.actualSize, in: .view, "Actual Size", key: .command("0"), availability: .sometimes),

        // MARK: Workspace

        MenuBarItem(.renameWorkspace, in: .workspace, "Rename", availability: .needsWorkspaceSubject),
        // The three that were on a workspace row's own menu and in no menu bar at all. None takes
        // a key: each is done once in a workspace's life, and a key spent here is a key not
        // available to something done every few minutes.
        MenuBarItem(.pin, in: .workspace, "Pin", alternateTitle: "Unpin", availability: .needsWorkspaceSubject),
        // The two labels are `UnreadMarkAction`'s rather than a second copy of them, because a
        // workspace row's menu draws the same item off that rule and the two must not word one
        // workspace differently.
        MenuBarItem(
            .unreadMark, in: .workspace, UnreadMarkAction.markUnread.title,
            alternateTitle: UnreadMarkAction.markRead.title, availability: .needsWorkspaceSubject
        ),
        MenuBarItem(.colour, in: .workspace, "Colour", availability: .needsWorkspaceSubject),
        // Landing the branch, which had no item in any menu: `requestMerge` was reachable from the
        // pull request band's button and from the bridge tool an agent calls, and from nothing at
        // the top of the screen. Directly above Archive because those two are the ends of a
        // workspace's life and that is the order they happen in.
        //
        // **No key, and that is the point of it having one fewer thing than the items around it.**
        // A key is worth spending on something done every few minutes; this is the most
        // consequential thing a person can ask Bloom to do to a branch and it happens once per
        // workspace. The item alone is what was missing.
        //
        // The title here is the greyed one. When the band is on screen the item says which merge,
        // because the method is a per-project mode and a row reading "Merge" over a project set to
        // squash is the fault the split button was built to remove. See `MergeAction`.
        MenuBarItem(.merge, in: .workspace, "Merge", availability: .sometimes),
        MenuBarItem(.archive, in: .workspace, "Archive Workspace", key: .init(.delete, .command), availability: .needsWorkspaceSubject),
        MenuBarItem(.restore, in: .workspace, "Restore Workspace", availability: .needsWorkspaceSubject),
        MenuBarItem(.openInEditor, in: .workspace, "Open in Editor", key: .init("e", .command, .shift), availability: .needsWorkspaceSubject),
        MenuBarItem(.revealInFinder, in: .workspace, "Reveal in Finder", key: .init("r", .command, .shift), availability: .needsWorkspaceSubject),
        // Copy Name is the window title's menu item, which was the only place in the app that put
        // a workspace's own name on the clipboard.
        MenuBarItem(.copyName, in: .workspace, "Copy Name", availability: .needsWorkspaceSubject),
        MenuBarItem(.copyBranchName, in: .workspace, "Copy Branch Name", key: .init("c", .command, .shift), availability: .needsWorkspaceSubject),
        // The one item whose title is not ours: `SetupRunOffer` words it, because the workspace
        // row's menu offers the same run and the two must not disagree about what it is called or
        // when it can be pressed.
        MenuBarItem(.runSetup, in: .workspace, "Run Setup", availability: .absentWhenUnavailable),
        MenuBarItem(.runScripts, in: .workspace, "Run", availability: .absentWhenUnavailable),
        MenuBarItem(.stopAgent, in: .workspace, "Stop Agent", key: .command("."), availability: .sometimes),

        // MARK: Help

        MenuBarItem(.help, in: .help, "Bloom Help", key: .command("?")),
        MenuBarItem(.welcome, in: .help, "Welcome to Bloom…"),
        MenuBarItem(.sendFeedback, in: .help, "Send Feedback…", key: .init("f", .command, .option)),
        MenuBarItem(.submitPrompt, in: .help, "Submit a Prompt…"),
        MenuBarItem(.postcardware, in: .help, "Send Us a Postcard…"),
    ]
}

/// The menus Bloom contributes items to.
///
/// Window is not here. Everything in it is SwiftUI's and AppKit's, and the one thing Bloom used to
/// add was a second item for the Discovered Seas window that a `Window` scene already contributes
/// for free. See the head of `OceansWindow`, which is where that measurement is written down.
public enum MenuBarMenu: String, CaseIterable, Sendable {
    case bloom
    case file
    case edit
    case view
    case workspace
    case help
}

/// One item of the menu bar, named so the app target and a test can refer to the same row.
///
/// A `String` raw value so a failing test names the item rather than an ordinal.
public enum MenuBarAction: String, CaseIterable, Sendable {
    case about
    case checkForUpdates

    case newWorkspace
    case newWorkspaceFromPullRequest
    case newAskConversation
    case projectSettings
    case newSession
    case newTerminalTab
    case newBrowserTab
    case showChanges
    case showNotes
    case renameTab
    case closeTab
    case startProject
    case save

    case find
    case findNext
    case findPrevious
    case search

    case splitRight
    case splitDown
    case closePane
    case zoomPane
    case focusPane
    case previousTab
    case nextTab
    case goToTab
    case nextChangedFile
    case previousChangedFile
    case toggleSidebar
    case toggleInspector
    case nextWorkspace
    case previousWorkspace
    case nextUnread
    case goToHome
    case goToAsk
    case zoomIn
    case zoomOut
    case actualSize

    case renameWorkspace
    case pin
    case unreadMark
    case colour
    case merge
    case archive
    case restore
    case openInEditor
    case revealInFinder
    case copyName
    case copyBranchName
    case runSetup
    case runScripts
    case stopAgent

    case help
    case welcome
    case sendFeedback
    case submitPrompt
    case postcardware
}

public struct MenuBarItem: Equatable, Sendable, Identifiable {
    public var action: MenuBarAction
    public var menu: MenuBarMenu
    /// What the row says. It matches the wording of the context menu offering the same thing,
    /// wherever both exist, so the two surfaces cannot teach different names for one action.
    public var title: String
    /// The other half of a two-state item, which is what Pin and the unread mark are. One row that
    /// changes its label rather than two rows one of which is always wrong.
    public var alternateTitle: String?
    public var key: MenuShortcut?
    /// The key is drawn on a row of this item's submenu rather than on the item itself, because
    /// AppKit never fires an item that has a submenu. Only the two splits do this.
    public var keyOnSameAgainRow: Bool
    public var availability: MenuBarAvailability

    public var id: MenuBarAction { action }

    init(
        _ action: MenuBarAction,
        in menu: MenuBarMenu,
        _ title: String,
        alternateTitle: String? = nil,
        key: MenuShortcut? = nil,
        keyOnSameAgainRow: Bool = false,
        availability: MenuBarAvailability = .always
    ) {
        self.action = action
        self.menu = menu
        self.title = title
        self.alternateTitle = alternateTitle
        self.key = key
        self.keyOnSameAgainRow = keyOnSameAgainRow
        self.availability = availability
    }

    /// The title for a two-state item, given which state it is in. `isAlternate` is "already
    /// pinned", "already unread", and so on.
    public func title(alternate isAlternate: Bool) -> String {
        isAlternate ? (alternateTitle ?? title) : title
    }
}

/// What has to be true before an item can be pressed, coarsely, so a reader can see which rows are
/// always live and the app target has one place to be consistent with.
///
/// It is not the rule. The rules live where the state does, and the ones that have been extracted
/// are named on the item that reads them.
public enum MenuBarAvailability: String, Equatable, Sendable {
    /// Never greyed.
    case always
    /// Greyed on something the core cannot hold: a running turn, an unread workspace, a window
    /// that has published a Save.
    case sometimes
    /// A project has been added.
    case needsProject
    /// A workspace is selected in the sidebar.
    case needsWorkspace
    /// Any workspace exists at all, selected or not.
    case needsAnyWorkspace
    /// A workspace is the Workspace menu's subject, and that subject allows this action. See
    /// `WorkspaceMenuSubject`.
    case needsWorkspaceSubject
    /// The centre column has a tab. See `TabClosure` for which one an action lands on.
    case needsTab
    /// The strip has more than one tab, so there is somewhere to move to. See `TabCycle`.
    case needsSeveralTabs
    /// The focused pane is one a split would actually open something beside. See `PaneSplit`.
    case needsSplittablePane
    /// The tab in front is a terminal, which is the only thing in the centre column with a shell
    /// tree to zoom or to step focus around.
    case needsTerminalPane
    /// A review is open and the worktree has something changed in it.
    case needsReview
    /// The one shape the menu bar does not grey: absent when the project defines none, because a
    /// permanently empty submenu teaches nothing either.
    case absentWhenUnavailable
}

/// A key equivalent, in a form the core can hold.
///
/// `KeyEquivalent` and `EventModifiers` belong to the framework only the app target may import,
/// and this table has to be readable by a suite that cannot see that target at all. The app maps
/// one onto the other in one place, so there is still exactly one spelling of every key.
public struct MenuShortcut: Equatable, Hashable, Sendable {
    public enum Trigger: Equatable, Hashable, Sendable {
        case character(Character)
        case upArrow
        case downArrow
        case leftArrow
        case rightArrow
        /// Backspace, which is what Archive Workspace takes.
        case delete
        case `return`
        /// The comma, spelled out because a literal comma in this table reads as a separator.
        case comma
    }

    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
    }

    public var trigger: Trigger
    public var modifiers: Modifiers

    public init(_ trigger: Trigger, _ modifiers: Modifiers...) {
        self.trigger = trigger
        self.modifiers = modifiers.reduce(into: []) { $0.formUnion($1) }
    }

    /// A character key, written as a one character string.
    ///
    /// A `String` rather than a `Character` so that every row of the table reads the same way, and
    /// so `"comma"` can be spelled out: a bare comma inside an argument list reads as a separator.
    /// It traps on anything else that is not one character, which is a table this module builds
    /// itself and therefore a typo caught the first time anything runs.
    public init(_ key: String, _ modifiers: Modifiers...) {
        if key == "comma" {
            self.trigger = .comma
        } else {
            precondition(key.count == 1, "a menu key is one character, or the word comma")
            self.trigger = .character(Character(key))
        }
        self.modifiers = modifiers.reduce(into: []) { $0.formUnion($1) }
    }

    /// The common case, spelled short so the table stays one row per item.
    public static func command(_ key: String) -> MenuShortcut {
        MenuShortcut(key, .command)
    }
}
