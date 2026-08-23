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

            Button("New Session") {
                guard let workspace = model.selectedModel else { return }
                Task { await workspace.createSession() }
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(model.selectedModel == nil)

            // Cmd+W belongs to the session, not the window. Bloom has no Save item, so a group
            // anchored after `.saveItem` is dropped whole and Cmd+W falls through to the system
            // Close, which used to end the process and every agent with it.
            //
            // It belongs to the session in the MAIN window, though, which is why it is scoped
            // to that scene below. The menu bar is shared with Settings and with each project's
            // settings window, and unscoped this item both closed the wrong thing from those
            // windows and left them with no working Cmd+W of their own.
            Button("Close Session") {
                guard let workspace = model.selectedModel,
                      let session = workspace.activeSession else { return }
                CloseSessionAlert.shared.close(session, in: workspace)
            }
            .keyboardShortcut("w", modifiers: .command)
            // Scoped to the main window as well as to there being a session, because this item
            // holds Cmd+W for the whole app. See `MainWindowFocus`.
            .disabled(isMainWindowFocused != true || model.selectedModel?.activeSession == nil)

            Divider()

            Button("Add Project Folder…", action: addProjectFolder)
            .keyboardShortcut("o", modifiers: [.command, .shift])
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
            Button("Split Right", systemImage: PaneSymbol.splitRight) { splitCentre(.horizontal) }
                .keyboardShortcut("\\", modifiers: .command)
                .disabled(model.selectedModel == nil)

            Button("Split Down", systemImage: PaneSymbol.splitDown) { splitCentre(.vertical) }
                .keyboardShortcut("\\", modifiers: [.command, .shift])
                .disabled(model.selectedModel == nil)

            Button("Close Pane", systemImage: PaneSymbol.closePane) { closeCentrePane() }
                .keyboardShortcut("w", modifiers: [.command, .control])
                .disabled(model.selectedModel == nil)

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

        CommandMenu("Workspace") {
            Button("Archive Workspace") {
                archiveSelectedWorkspace()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(model.selectedWorkspace == nil)

            // The way back, which the menu bar had no item for at all. Before this the only path
            // to `restoreArchived` in the whole app was the undo registered by the archive that
            // had just happened, so a workspace archived yesterday could not be brought back from
            // anywhere. See `ArchivedWorkspaceView` for why reading it and restoring it are two
            // different things.
            Button("Restore Workspace") {
                restoreArchivedWorkspace()
            }
            .disabled(
                model.selectedArchivedWorkspace == nil
                    || model.selectedArchivedWorkspace.map { model.restoring.contains($0.id) } == true
            )

            Divider()

            Button("Open in Editor") {
                guard let workspace = model.selectedWorkspace else { return }
                Reveal.inEditor(workspace.path)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(model.selectedWorkspace == nil)

            Button("Reveal in Finder") {
                guard let workspace = model.selectedWorkspace else { return }
                Reveal.inFinder(workspace.path)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model.selectedWorkspace == nil)

            // `menuWorkspace`, not `selectedWorkspace`: a branch name is the one thing on this
            // menu that still means something once the worktree has been removed, and it is what
            // somebody reading an archived workspace reaches for.
            Button("Copy Branch Name") {
                guard let workspace = model.menuWorkspace else { return }
                Clipboard.copy(workspace.branch)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(model.menuWorkspace == nil)

            Divider()

            setupItem

            runScriptsMenu

            Button("Stop Agent") {
                model.selectedModel?.activeTranscript?.stop()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(model.selectedModel?.activeTranscript?.isRunning != true)
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
    private func splitCentre(_ axis: SplitAxis) {
        guard let workspace = model.selectedModel else { return }
        let tabs = WorkspaceTabsStore.shared
        guard let tab = tabs.selectedTab(in: workspace) else { return }
        let pane = tabs.focusedPane(of: tab)

        PaneDuplicate.open(tabs.content(of: pane, in: tab), in: workspace) { content in
            tabs.split(tab: tab, pane: pane, axis: axis, showing: content)
        }
    }

    private func closeCentrePane() {
        guard let workspace = model.selectedModel else { return }
        let tabs = WorkspaceTabsStore.shared
        guard let tab = tabs.selectedTab(in: workspace) else { return }
        tabs.close(
            pane: tabs.focusedPane(of: tab), in: tab, of: workspace.workspace.id
        )
    }

    private func addProjectFolder() {
        Task {
            guard let path = await ProjectFolderPicker.choose() else { return }
            await model.addRepository(at: path)
        }
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
    private func archiveSelectedWorkspace() {
        guard let workspace = model.selectedWorkspace else { return }
        Task { await model.archive(workspace) }
    }

    private func restoreArchivedWorkspace() {
        guard let workspace = model.selectedArchivedWorkspace else { return }
        Task { await model.restore(workspace) }
    }
}
