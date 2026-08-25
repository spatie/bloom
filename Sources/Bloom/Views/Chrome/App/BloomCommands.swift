import AppKit
import SwiftUI
import BloomCore

/// Keeps keyboard-driven navigation available even when focus is inside a transcript or terminal.
@MainActor
struct BloomCommands: Commands {
    private let model: AppModel

    /// Read rather than queried, so the size items grey and ungrey as the sizes and the focus move.
    /// See `TextZoomAvailability`.
    private let zoom = TextZoomAvailability.shared

    /// Read for the same reason `zoom` is: this body is not a view, so the item only greys and
    /// ungreys because an `@Observable` it reads has moved. See `SoftwareUpdater`.
    private let updater = SoftwareUpdater.shared

    /// Nil in every scene but the main window. See `MainWindowFocus`.
    @FocusedValue(\.isMainWindowFocused) private var isMainWindowFocused: Bool?

    /// The row Home or the Archive has highlighted, which is what the Workspace menu acts on when
    /// the sidebar is not pointing at a workspace itself. See `FocusedMenuValues`.
    @FocusedValue(\.focusedWorkspaceRow) private var focusedRow: FocusedWorkspaceRow?

    /// The focused window's Save, when it has one. See `FocusedMenuValues`.
    @FocusedValue(\.saveAction) private var saveAction: SaveAction?

    init(model: AppModel) {
        self.model = model
    }

    var body: some Commands {
        // Bloom's own About window rather than AppKit's panel. `orderFrontStandardAboutPanel` can
        // be handed the bundle's keys and a paragraph of credits and nothing else: no mark, no
        // typeface, no ground. Everything that makes this app recognisable as the one runbloom.app
        // is about lives in exactly those three, so the panel was the wrong shape for what this
        // window has to say. See `AboutWindow`.
        //
        // Replacing rather than adding to, because the item AppKit puts here cannot be pointed
        // somewhere else. The update check below stays a group of its own so the separator between
        // the two is still there.
        CommandGroup(replacing: .appInfo) {
            Button("About Bloom") {
                AboutWindow.show()
            }
        }

        // Directly under "About Bloom", which is where every Mac app that updates itself puts it
        // and therefore the first place anyone looks. Not in the Help menu, and not in Settings
        // only: the Settings switch decides whether Bloom looks on its own, and this asks now.
        //
        // Absent rather than greyed out on a build that cannot update itself, because a permanently
        // dead menu item invites the same click every time. See `SoftwareUpdate.availability`.
        CommandGroup(after: .appInfo) {
            if case .configured = updater.availability {
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }
        }

        CommandGroup(replacing: .newItem) {
            Button("New Workspace…") {
                // The sheet lives in RootView, and the sidebar and Home already open it this
                // way. Setting a flag on the model instead would leave it stuck true with no
                // sheet.
                NotificationCenter.default.post(name: .bloomNewWorkspace, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(model.repos.isEmpty)

            // Directly under New Workspace, because it starts one, and at the top level of File
            // rather than nowhere. Opening a workspace on somebody else's pull request was a whole
            // feature that could only be found by opening the create sheet, opening its "Start
            // from" control and reading down past a list of branches: two levels in, behind a
            // control most people never press, which is the same as not shipping it.
            //
            // No key equivalent. It is the rarer of the two ways to start a workspace and the item
            // alone is what was missing.
            Button("New Workspace from Pull Request…") {
                NotificationCenter.default.post(
                    name: .bloomNewWorkspace, object: nil,
                    userInfo: [Notification.bloomPullRequestKey: true]
                )
            }
            .disabled(model.repos.isEmpty)

            Button("New Session") {
                guard let workspace = model.selectedModel else { return }
                Task { await workspace.createSession() }
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(model.selectedModel == nil)

            // The other four things that open a tab in the workspace's centre column, which until
            // now existed only as key equivalents on hidden buttons inside `SessionTabsView`. The
            // `+` at the end of the tab strip listed them and drew their shortcuts, but a `Menu`
            // in a view cannot fire a key equivalent, so the keys were registered a second time on
            // an invisible `ZStack` of buttons. Four bindings with no menu item anywhere is four
            // bindings nobody could discover.
            //
            // The keys moved here rather than being registered here as well. Measured on a
            // reduction of the two registrations, a `CommandMenu` item and a view hierarchy
            // button carrying the same key: the button wins and the menu item never fires. So a
            // second registration would have left four menu items drawn with keys that ran the
            // hidden buttons instead, which is the same feature with more places for it to come
            // apart. The hidden buttons are gone and these carry the keys.
            //
            // All four in File, next to New Session, rather than the review and the notes going to
            // View. They are one family: each opens one of the five kinds of tab a workspace has,
            // and New Session above them opens the fifth. Splitting them would also split
            // Shift+Cmd+T, B, D and N across two menus, and it is the shape of that set that makes
            // it learnable.
            Divider()

            Button("New Terminal Tab") { openPane(.terminal) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(model.selectedModel == nil)

            Button("New Browser Tab") { openBrowserPane() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(model.selectedModel == nil)

            // The same key both ways, as the hidden button had it: show me the change, or give me
            // the conversation back. Enabled on any selected workspace rather than only on one
            // with changes, unlike the `+` menu's own row, because half of what this key does is
            // the way back out of a review and a workspace can have a review open with nothing
            // left in it.
            Button("Show Changes") {
                guard let workspace = model.selectedModel else { return }
                FileReview.toggle(in: workspace)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(model.selectedModel == nil)

            // Shift+Cmd+N, which nothing in Bloom held. It is the initial of the thing, which is
            // what the other three in this group are, and that pattern is the only reason a set
            // of four is easier to remember than four separate facts. Never disabled beyond
            // needing a workspace, because an empty note is exactly what somebody opening this is
            // about to fix.
            Button("Show Notes") {
                guard let workspace = model.selectedModel else { return }
                WorkspaceNotes.open(in: workspace)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(model.selectedModel == nil)

            Divider()

            // Cmd+W belongs to the tab, not the window, and this used to be Close Session, which
            // is not the same claim. It closed the workspace's active conversation whatever was in
            // front, so on a browser, a review or the notes it ended a chat in some other pane,
            // silently whenever that chat was idle. Four kinds of tab could be opened from the
            // keyboard and none of them could be closed.
            //
            // There is no Close Session beside it, because a conversation IS a tab in this strip
            // and closing one still asks what `SessionClosure` asks. The obvious second half,
            // moving Close Session to Shift+Cmd+W, is not available: that key is the window's own
            // Close and has to stay so. See `WindowDismissal` and `TabClosure`.
            //
            // It belongs to the tab in the MAIN window, though, which is why it is scoped to that
            // scene below. The menu bar is shared with Settings and with each project's settings
            // window, and unscoped this item both closed the wrong thing from those windows and
            // left them with no working Cmd+W of their own.
            Button("Close Tab") {
                closeSelectedTab()
            }
            .keyboardShortcut("w", modifiers: .command)
            // Scoped to the main window as well as to there being a tab, because this item holds
            // Cmd+W for the whole app. See `MainWindowFocus`.
            .disabled(isMainWindowFocused != true || closableTab == nil)

            Divider()

            Button("Add Project Folder…", action: addProjectFolder)
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }

        // The item this file used to say did not exist. Two views bind Cmd+S (the project settings
        // window's save bar and the inspector's file editor) and the menu bar advertised neither,
        // which is a key equivalent nobody can discover.
        //
        // `.saveItem` is where every Mac app puts it, under the Close group, and having a real one
        // there also gives that placement something to anchor against for the first time.
        //
        // The key is on the item as well as on the button that publishes the action, which is a tie
        // AppKit settles in the view hierarchy's favour: the button wins and this item never fires
        // from the keyboard. That is fine and is why both exist. What this adds is the row, its
        // key drawn where people look for it, and a target for the pointer. Where nothing has
        // published a Save the item is disabled, and a disabled item does not consume its key, so a
        // view that still keeps Cmd+S to itself keeps working. See `FocusedMenuValues`.
        CommandGroup(replacing: .saveItem) {
            Button("Save") { saveAction?.perform() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(saveAction?.isEnabled != true)
        }

        CommandGroup(after: .pasteboard) {
            // The separator matters more than it looks. `.pasteboard` ends at Select All, so
            // without this the find item sits welded to it and the Edit menu reads as one
            // undivided run of eight items. Every Mac Edit menu keeps find in a group of its own.
            Divider()

            // "Search", not "Find Workspace". This opens the sidebar's own Search, which reads
            // the full text of every transcript as well as workspace names, so the old title
            // named the smaller half of what it does and nobody would have guessed the rest was
            // there. The sidebar item it selects is called Search, and one thing wants one name.
            //
            // No ellipsis: it puts a screen up in the window rather than raising anything to fill
            // in, which is what the ellipsis promises.
            Button("Search") {
                model.selection = .search
            }
            .keyboardShortcut("f", modifiers: .command)
            // Keyed on projects rather than on live workspaces, because search now also finds
            // archived ones and a machine whose every workspace is archived still has something
            // to find. See `AppModel.search`.
            .disabled(model.repos.isEmpty)
        }

        // Splitting the centre column. Cmd+D is deliberately not used: a terminal pane already
        // owns it for splitting shells, and one keystroke that splits two different things
        // depending on where the pointer last was is worse than two that each mean one thing.
        CommandGroup(after: .sidebar) {
            // Greyed on a tab that cannot be split rather than on no workspace at all. The
            // review and the notes have exactly one copy each by design, so `PaneDuplicate` has
            // always refused them, and these two items said nothing about it: on the Notes tab
            // Split Right read as available and then did nothing when it was pressed. See
            // `PaneSplit` in the core, which is the rule both sides read now.
            Button("Split Right", systemImage: PaneSymbol.splitRight) { splitCentre(.horizontal) }
                .keyboardShortcut("\\", modifiers: .command)
                .disabled(!canSplitCentre)

            Button("Split Down", systemImage: PaneSymbol.splitDown) { splitCentre(.vertical) }
                .keyboardShortcut("\\", modifiers: [.command, .shift])
                .disabled(!canSplitCentre)

            Button("Close Pane", systemImage: PaneSymbol.closePane) { closeCentrePane() }
                .keyboardShortcut("w", modifiers: [.command, .control])
                .disabled(model.selectedModel == nil)

            Divider()

            // Cmd+Shift+[ and ], which is what Safari, Terminal, Xcode and Finder all bind.
            //
            // Every kind of centre tab could already be opened from the keyboard, and none of
            // them could be moved between: the full shortcut grep across this app found 74
            // bindings and not one for `[`, `]`, Ctrl+Tab or Cmd+1, and there was no menu item to
            // carry one. Which tab is next is `TabCycle` in the core, wrapping included.
            Button("Previous Tab") { cycleCentreTab(by: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(!canCycleCentreTabs)

            Button("Next Tab") { cycleCentreTab(by: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(!canCycleCentreTabs)

            goToTabMenu

            Divider()

            // The walk through a change, which used to be two invisible buttons inside
            // `ReviewPaneView` carrying Cmd+Option+J and K with no menu item anywhere. The four tab
            // keys made this move first and wrote down the measurement: a key registered on a
            // hidden button and on a menu item is not a tie, the button wins and the item never
            // fires, so it has to be one or the other. Here it is the menu, which greys itself out
            // when there is nothing to step through and says the keys out loud.
            Button("Next Changed File") { stepChangedFile(1) }
                .keyboardShortcut("j", modifiers: [.command, .option])
                .disabled(!canStepChangedFiles)

            Button("Previous Changed File") { stepChangedFile(-1) }
                .keyboardShortcut("k", modifiers: [.command, .option])
                .disabled(!canStepChangedFiles)

            Divider()
        }

        CommandGroup(after: .sidebar) {
            Button("Toggle Sidebar") {
                // `NavigationSplitView` owns the sidebar's visibility through the binding RootView
                // holds, not through `toggleSidebar(_:)` on the responder chain, so this goes to
                // RootView rather than to first responder.
                NotificationCenter.default.post(name: .bloomToggleSidebar, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .control])

            Button("Toggle Inspector") {
                guard model.selectedModel != nil else { return }
                model.isInspectorVisible.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(model.selectedModel == nil)

            Divider()

            Button("Next Workspace") {
                model.selectNextWorkspace(offset: 1)
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            .disabled(model.workspaces.isEmpty)

            Button("Previous Workspace") {
                model.selectNextWorkspace(offset: -1)
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            .disabled(model.workspaces.isEmpty)

            Button("Next Unread") {
                model.selectNextUnread()
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(!model.workspaces.contains(where: \.unread))

            // Cmd+Shift+H, not Cmd+0. Cmd+0 is Actual Size on this platform and now belongs to the
            // Zoom group below; two items in one menu cannot share a key equivalent, and the one
            // AppKit finds first would silently have killed the other. Cmd+Shift+H is what Home is
            // bound to in Finder and in Safari anyway, so this is where it should always have been.
            Button("Go to Home") {
                model.selection = .home
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .disabled(model.selection == .home)
        }

        // Zoom, at the foot of the View menu, where Safari, Preview and Notes all keep it, and
        // named as they name it. "Actual Size" only reads as a way back next to "Zoom In", which
        // is why the whole trio is borrowed rather than Mail's pair of Bigger and Smaller.
        //
        // Each item resolves its own target when it fires. See `TextZoom`.
        CommandGroup(after: .sidebar) {
            Divider()

            Button("Zoom In") { TextZoom.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!zoom.canZoomIn)

            Button("Zoom Out") { TextZoom.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!zoom.canZoomOut)

            Button("Actual Size") { TextZoom.actualSize() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(!zoom.canResetSize)
        }

        // Every item here used to be gated on `AppModel.selectedWorkspace`, which is the sidebar's
        // selection and nothing else. On Home the selection is `.home` and in the Archive it is
        // `.archive`, so a row highlighted in either list left this whole menu greyed out while the
        // user was pointing straight at the workspace it names. What each item acts on now is
        // `WorkspaceMenuSubject` in the core, resolved from the selection and from whichever list
        // has published a row, with the precedence and the archived cases held by its tests.
        CommandMenu("Workspace") {
            // Rename had no menu item at all: it existed on the row context menus alone, which a
            // keyboard-only user reaches only through VoiceOver. No key equivalent, because Finder
            // gives Rename none either and both lists already spend Return on opening a row.
            Button("Rename") {
                guard let workspace = workspace(for: .rename) else { return }
                NotificationCenter.default.post(
                    name: .bloomRenameWorkspace, object: nil,
                    userInfo: [Notification.bloomWorkspaceIDKey: workspace.id.rawValue]
                )
            }
            .disabled(workspace(for: .rename) == nil)

            Divider()

            Button("Archive Workspace") {
                guard let workspace = workspace(for: .archive) else { return }
                archive(workspace)
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(workspace(for: .archive) == nil)

            // The way back, which the menu bar had no item for at all. Before this the only path
            // to `restoreArchived` in the whole app was the undo registered by the archive that
            // had just happened, so a workspace archived yesterday could not be brought back from
            // anywhere. See `ArchivedWorkspaceView` for why reading it and restoring it are two
            // different things.
            Button("Restore Workspace") {
                guard let workspace = restorableWorkspace else { return }
                Task { await model.restore(workspace) }
            }
            .disabled(restorableWorkspace == nil)

            Divider()

            Button("Open in Editor") {
                guard let workspace = workspace(for: .openInEditor) else { return }
                Reveal.inEditor(workspace.path)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(workspace(for: .openInEditor) == nil)

            Button("Reveal in Finder") {
                guard let workspace = workspace(for: .revealInFinder) else { return }
                Reveal.inFinder(workspace.path)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(workspace(for: .revealInFinder) == nil)

            // The one item an archived workspace still answers to. A branch name means something
            // once the worktree has gone, and opening an editor on a path that is not there does
            // not: that pair is the whole of `WorkspaceMenuSubject.allows`.
            Button("Copy Branch Name") {
                guard let workspace = workspace(for: .copyBranchName) else { return }
                Clipboard.copy(workspace.branch)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(workspace(for: .copyBranchName) == nil)

            Divider()

            setupItem

            runScriptsMenu

            // The subject's own model rather than the selected one, so a row highlighted on Home
            // stops the agent that row is about. It is `existingModel`, which only reads: a
            // workspace this launch has never opened has no transcript to stop anyway.
            Button("Stop Agent") {
                subjectModel?.activeTranscript?.stop()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(subjectModel?.activeTranscript?.isRunning != true)
        }

        CommandGroup(replacing: .help) {
            // The docs, not the repository. This pointed at github.com/spatie/Bloom#readme,
            // which is not where Bloom lives and would have 404'd for everyone who pressed it.
            Button("Bloom Help") {
                guard let url = URL(string: "https://runbloom.app/docs") else { return }
                NSWorkspace.shared.open(url)
            }
            .keyboardShortcut("?", modifiers: .command)

            // The first run window, on demand. A real item rather than a debug flag: somebody who
            // waved the welcome away and wants it back has exactly the same need as somebody who
            // has never seen it, and "was anything wrong with my setup" is a Help menu question
            // in every Mac app that can answer it. It re-checks on every visit, so it is also the
            // shortest way to find out whether the CLI you just installed was found.
            Button("Welcome to Bloom…") {
                WelcomeWindow.show()
            }

            Divider()

            // The two ways to say something back. In the Help menu because that is where a Mac
            // app keeps "how do I reach these people", and next to each other because they are
            // the same gesture aimed at two different answers: one asks for something to be
            // fixed, the other asks for something to be built.
            //
            // Option+Command+F rather than Command+F, which is Search and stays that way.
            // The sheets themselves are raised from `RootView`, through `FeedbackPresenter`, for
            // the reason the create sheet is: a menu item cannot present anything, and the draft
            // has to outlive the sheet it was typed into.
            Button("Send Feedback…") {
                FeedbackPresenter.shared.open(.report)
            }
            .keyboardShortcut("f", modifiers: [.command, .option])

            Button("Submit a Prompt…") {
                FeedbackPresenter.shared.open(.prompt)
            }
        }
    }

    /// Running this repository's setup script in this worktree again.
    ///
    /// In the Workspace menu rather than in the project settings window, and the reason is what
    /// the action needs: a setup script runs in ONE worktree, against ONE port, and writes its
    /// outcome onto ONE workspace row. The settings window is about a project, which usually has
    /// several workspaces open, so a button there would have to guess which of them was meant, or
    /// grow a picker to ask. Here the answer is the workspace the window is already showing.
    ///
    /// It is also where the two people who press it are. One has just read a failure and wants
    /// another go; the transcript's own failed row carries the same action for them, so they never
    /// have to leave the sentence explaining what went wrong. The other has just edited the script
    /// in the project settings window, and comes back to the workspace to try it.
    ///
    /// It is no longer the only menu with it. A workspace row's own menu carries it as well, which
    /// is where somebody who is thinking about one workspace rather than about the app looks
    /// first: this item was in the menu bar alone for long enough that its author went hunting for
    /// it on the row and could not find it. See `WorkspaceMenuItems`.
    ///
    /// Greyed rather than absent while it runs, because the reason it cannot be pressed is that it
    /// is already doing the thing, and an item that vanished mid run would read as the feature
    /// having gone away. That, and the absent case beside it, are `SetupRunOffer` now: the same
    /// item is on a workspace row's own menu, and the two must not word it differently or disagree
    /// about when it can be pressed.
    @ViewBuilder
    private var setupItem: some View {
        if let workspace = model.selectedModel, let offer = workspace.setupRunOffer {
            Button(offer.title) { workspace.runSetupAgain() }
                .disabled(!offer.isEnabled)
        }
    }

    /// The repository's run scripts, each of which opens a terminal tab named after itself with
    /// its command already running.
    ///
    /// In the Workspace menu because a run script runs in one worktree, against one port, and the
    /// project settings window that defines them is not about any particular workspace. They used
    /// to be tabs in the panel at the bottom of the inspector, each with its own start, stop and
    /// restart bar over a read-only log. A terminal is that and more: Ctrl+C stops the server, Up
    /// and Return start it again, and the pane can be split, moved and put beside the conversation
    /// like every other tab in the column.
    ///
    /// Absent rather than greyed out when the repository has none, because a permanently empty
    /// submenu teaches nothing. See `WorkspaceModel.refreshSettings` for when the list is read.
    @ViewBuilder
    private var runScriptsMenu: some View {
        if let workspace = model.selectedModel, !workspace.settings.runScripts.isEmpty {
            Menu("Run") {
                ForEach(workspace.settings.runScripts) { script in
                    Button(script.name) { run(script, in: workspace) }
                }
            }

            Divider()
        }
    }

    /// A new tab every time, rather than one that is reused. Two copies of a dev server is a thing
    /// somebody does on purpose, and a tab that silently restarted the one already running would
    /// throw away the log they were reading.
    private func run(_ script: RunScript, in workspace: WorkspaceModel) {
        let tab = CenterTabStore.shared.add(
            kind: .terminal, workspaceID: workspace.workspace.id, title: script.name
        )
        // Queued rather than sent: the shell is forked by `ToolPaneView`, once it has settled the
        // port this script is about to bind. See `TerminalSessionStore.run(_:inPaneID:)`.
        TerminalSessionStore.shared.run(script.command, inPaneID: tab.id)
        WorkspaceTabsStore.shared.select(.tool(tab.id), in: workspace)
    }

    /// Splits the pane the user is in and shows the same thing in the half that opens, which is
    /// what splitting means in every editor: the same thing twice, and then you change one of them.
    ///
    /// A shell or a page cannot actually be shown twice, and asking for it has been possible here
    /// since panes existed. `PaneDuplicate` is where that is refused and a fresh one of the same
    /// kind offered instead; it is the same door the strip's own split items use.
    /// Whether Split Right and Split Down would actually open a pane, read on every rebuild of
    /// this body. `WorkspaceTabsStore` and `CenterTabStore` are both `@Observable`, so selecting
    /// another tab greys and ungreys the two items on its own, the way `zoom` does above.
    private var canSplitCentre: Bool {
        guard let workspace = model.selectedModel else { return false }
        let tabs = WorkspaceTabsStore.shared
        guard let tab = tabs.selectedTab(in: workspace) else { return false }
        return PaneDuplicate.canOpen(tabs.content(of: tabs.focusedPane(of: tab), in: tab), in: workspace)
    }

    private func splitCentre(_ axis: SplitAxis) {
        guard let workspace = model.selectedModel else { return }
        let tabs = WorkspaceTabsStore.shared
        guard let tab = tabs.selectedTab(in: workspace) else { return }
        let pane = tabs.focusedPane(of: tab)

        PaneDuplicate.open(tabs.content(of: pane, in: tab), in: workspace) { content in
            tabs.split(tab: tab, pane: pane, axis: axis, showing: content)
        }
    }

    /// Greyed on a strip with nothing to move to, rather than on no workspace at all, which is
    /// the same rule Split Right follows two items above.
    private var canCycleCentreTabs: Bool {
        guard let workspace = model.selectedModel else { return false }
        return WorkspaceTabsStore.shared.entries(in: workspace).count > 1
    }

    private func cycleCentreTab(by offset: Int) {
        guard let workspace = model.selectedModel else { return }
        WorkspaceTabsStore.shared.selectNextTab(offset: offset, in: workspace)
    }

    /// Cmd+1 to Cmd+9, and the only place in the app a tab can be reached by name from the
    /// keyboard.
    ///
    /// Bloom bound neither these nor Ctrl+Tab: the full shortcut grep found 74 bindings and not one
    /// digit, so in a strip of five tabs the fifth was four presses of Cmd+Shift+]. Safari,
    /// Terminal and Xcode all bind them, and all give 9 to the last tab rather than to the ninth.
    ///
    /// A submenu that lists the tabs by their own names rather than nine items called Tab 1, which
    /// is how Terminal's Window menu draws the same keys, and it means the menu answers "what is
    /// open in this workspace" as well as carrying the shortcut. Which number reaches which tab is
    /// `TabCycle.numbered` in the core.
    @ViewBuilder
    private var goToTabMenu: some View {
        if let workspace = model.selectedModel {
            let entries = WorkspaceTabsStore.shared.entries(in: workspace)
            Menu("Go to Tab") {
                ForEach(TabCycle.numbered(entries), id: \.tab) { entry in
                    tabItem(entry.tab, ordinal: entry.ordinal, in: workspace)
                }
            }
            .disabled(entries.isEmpty)
        }
    }

    @ViewBuilder
    private func tabItem(_ tab: PaneContent, ordinal: Int?, in workspace: WorkspaceModel) -> some View {
        let button = Button(tabTitle(tab, in: workspace)) {
            WorkspaceTabsStore.shared.select(tab, in: workspace)
        }
        if let ordinal {
            button.keyboardShortcut(KeyEquivalent(Character("\(ordinal)")), modifiers: .command)
        } else {
            button
        }
    }

    /// What a tab is called in the strip, so the menu and the strip cannot say two different names
    /// for one tab.
    private func tabTitle(_ tab: PaneContent, in workspace: WorkspaceModel) -> String {
        switch tab {
        case .chat(let id):
            let title = workspace.sessions.first { $0.id == id }?.title ?? ""
            return title.isEmpty ? "Untitled" : title
        case .tool(let id):
            guard let tool = CenterTabStore.shared.tabs(for: workspace.workspace.id)
                .first(where: { $0.id == id }) else { return "Tab" }
            return CenterTabStore.shared.displayTitle(of: tool, in: workspace)
        }
    }

    // MARK: - Closing what is in front

    /// What Cmd+W would close: the tab in front, or the pane of it the keyboard is in. See
    /// `TabClosure`, which is the rule and which the tests hold.
    private var closableTab: PaneContent? {
        guard let workspace = model.selectedModel else { return nil }
        let tabs = WorkspaceTabsStore.shared
        guard let tab = tabs.selectedTab(in: workspace) else { return nil }
        return TabClosure.target(
            selectedTab: tab,
            focusedPaneContent: tabs.content(of: tabs.focusedPane(of: tab), in: tab)
        )
    }

    /// Closing a conversation still goes through `CloseSessionAlert`, which asks when there is
    /// something to lose by it and never asks when there is not. That is the whole of what the old
    /// Close Session did, so nothing about a chat closes more quietly than it used to.
    private func closeSelectedTab() {
        guard let workspace = model.selectedModel, let target = closableTab else { return }
        switch target {
        case .chat(let id):
            guard let session = workspace.sessions.first(where: { $0.id == id }) else { return }
            CloseSessionAlert.shared.close(session, in: workspace)
        case .tool(let id):
            guard let tab = CenterTabStore.shared.tabs(for: workspace.workspace.id)
                .first(where: { $0.id == id }) else { return }
            Task { await CenterTabStore.shared.close(tab) }
        }
    }

    // MARK: - Walking a review

    /// Greyed when there is no review open or nothing changed in the worktree, which is the state
    /// the two hidden buttons expressed by not existing.
    private var canStepChangedFiles: Bool {
        guard let workspace = model.selectedModel, !workspace.changedFiles.isEmpty else {
            return false
        }
        return CenterTabStore.shared.review(for: workspace.workspace.id) != nil
    }

    private func stepChangedFile(_ delta: Int) {
        guard let workspace = model.selectedModel else { return }
        FileReview.step(delta, in: workspace)
    }

    private func closeCentrePane() {
        guard let workspace = model.selectedModel else { return }
        let tabs = WorkspaceTabsStore.shared
        guard let tab = tabs.selectedTab(in: workspace) else { return }
        tabs.close(
            pane: tabs.focusedPane(of: tab), in: tab, of: workspace.workspace.id
        )
    }

    /// A terminal in a new tab, placed and selected exactly as the tab strip's own `+` does it.
    private func openPane(_ kind: PaneKind) {
        guard let workspace = model.selectedModel else { return }
        NewPane.open(kind, in: workspace) {
            WorkspaceTabsStore.shared.select($0, in: workspace)
        }
    }

    /// A browser on the workspace's own dev server, which is what the `+` opens and what a split
    /// does not: this is the route that has a port to hand. See `SessionTabsView.newBrowser`.
    private func openBrowserPane() {
        guard let workspace = model.selectedModel else { return }
        Task {
            await workspace.ensurePort()
            let address = workspace.port > 0 ? "http://localhost:\(workspace.port)" : ""
            NewPane.open(.browser, in: workspace, url: address) {
                WorkspaceTabsStore.shared.select($0, in: workspace)
            }
        }
    }

    private func addProjectFolder() {
        Task {
            guard let path = await ProjectFolderPicker.choose() else { return }
            await model.addRepository(at: path)
        }
    }

    // MARK: - What the Workspace menu is about

    /// The workspace the menu acts on, live or archived, decided by `WorkspaceMenuSubject`.
    private var subject: WorkspaceMenuSubject? {
        WorkspaceMenuSubject.resolve(selection: model.selection, focusedRow: focusedRow?.row)
    }

    /// The workspace an item may act on, or nil, which is the same answer the item's `disabled`
    /// reads. Asked twice per item on purpose: the action and the greying must not be able to
    /// disagree, and both are a dictionary lookup over values already in memory.
    private func workspace(for action: WorkspaceMenuAction) -> Workspace? {
        guard let subject, subject.allows(action) else { return nil }
        // The row a list published carries the workspace itself, which is the only way to reach an
        // ARCHIVED one: `AppModel` deliberately holds live workspaces alone, so an archived row
        // highlighted on Home is nowhere else in memory.
        if let focusedRow, focusedRow.workspace.id == subject.id { return focusedRow.workspace }
        return [model.selectedWorkspace, model.selectedArchivedWorkspace]
            .compactMap { $0 }
            .first { $0.id == subject.id }
    }

    /// Restore, which additionally has to say no while one is already running.
    private var restorableWorkspace: Workspace? {
        guard let workspace = workspace(for: .restore),
              !model.restoring.contains(workspace.id) else { return nil }
        return workspace
    }

    /// The live model behind the subject, when this launch has one. Only Stop Agent asks: setup
    /// and the run scripts need a workspace whose settings have been read, which is the one the
    /// window is actually showing.
    private var subjectModel: WorkspaceModel? {
        guard let id = subject?.liveID else { return nil }
        return model.existingModel(for: id)
    }

    /// Straight through to `AppModel.archive`, exactly as the sidebar's context menu and the
    /// window title's menu do.
    ///
    /// It used to raise an alert of its own first, which said only "The worktree will be removed."
    /// That is the one thing an archive always does, so it named nothing that was actually at
    /// stake, and it appeared on the routine archive as well, which is how a confirmation stops
    /// being read. `AppModel.archive` runs a git safety check and only stops when there is
    /// something specific to lose, and then it says what. Keeping both meant this shortcut alone
    /// asked twice on the dangerous archive and asked a useless question on the safe one.
    private func archive(_ workspace: Workspace) {
        Task { await model.archive(workspace) }
    }
}
