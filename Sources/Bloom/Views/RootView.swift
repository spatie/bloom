import SwiftUI
import BloomCore

/// The window: a real `NavigationSplitView` with a real toolbar.
///
/// This used to be a hand-rolled `HStack` with its own drag handles, which is precisely why the
/// window had no title bar, no toolbar, an opaque sidebar and a hard divider running straight
/// through the traffic lights. `NavigationSplitView` hands all of that back to AppKit: the
/// translucent sidebar material, the sidebar toggle, traffic light placement, unified toolbar
/// integration and remembered column widths. The centre column and the inspector are an AppKit
/// `NSSplitViewController`, for the reason spelled out on `DetailSplitViewController`.
///
/// The columns themselves are `SidebarView` and `DetailColumn`, and the toolbar is
/// `BloomWindowToolbar`. What is left here is only what belongs to the window as a whole: the
/// split view, the inspector, the create sheet, the archive confirmation and the alert.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow

    @Bindable private var projectSetup = ProjectSetup.shared
    @Bindable private var closeSession = CloseSessionAlert.shared
    @Bindable private var setupRun = SetupRunAlert.shared
    /// The two Help menu sheets, and the drafts typed into them. See `FeedbackPresenter`.
    @Bindable private var feedback = FeedbackPresenter.shared

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Whether the window's search field has the keyboard. Shift+Cmd+F, and Cmd+F where nothing in
    /// front can find, put it here. See `FindCommand`.
    @FocusState private var isSearchFocused: Bool
    @State private var isCreateSheetPresented = false
    @State private var createTargetRepo: Repo?
    /// Set by the File menu's pull request item and by nothing else. See `CreateWorkspaceSheet`.
    @State private var createStartsOnPullRequest = false

    var body: some View {
        @Bindable var app = app

        return NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
            // The sidebar's ground is set here rather than inside `SidebarView`, because what has
            // to be replaced is the `List`'s own scroll background, and that is a property of the
            // column rather than of anything the sidebar draws. See `sidebarMaterial` for why a
            // named colour beats the system's vibrant one in a window with a themed ramp.
            .scrollContentBackground(.hidden)
            .sidebarMaterial()
            // The rule down the sidebar's trailing edge.
            //
            // `NavigationSplitView` draws none: measured across the boundary, the sidebar's last
            // pixel is followed directly by the centre column's first, in both appearances. That
            // is survivable while both columns are the system's own white, and it is not once
            // they are two steps of a ramp, because then the two panes simply run into each other.
            .overlay(alignment: .trailing) { Hairline(axis: .vertical) }
            .navigationSplitViewColumnWidth(
                min: 200, ideal: Metrics.sidebarWidth, max: BloomApp.sidebarMaximumWidth
            )
        } detail: {
            // An `NSSplitViewController`, not `.inspector()` and not `HSplitView`.
            //
            // `.inspector` cannot be used in this window. Presented, it throws "more Update
            // Constraints in Window passes than there are views in the window" out of the display
            // cycle, from a loop that runs through SwiftUI's own `SplitViewChildController`
            // reacting to its hosting view's min and max size. Verified again on this branch:
            // swapping the split below for `.inspector()` kills the window during a resize.
            //
            // `HSplitView` was the next attempt and it did not crash, but its divider is drawn
            // down the whole bounds of the split view while the SwiftUI content inside each pane
            // respects the safe area, so under a unified toolbar a hard rule crossed the title.
            // An `NSSplitViewController` is a view controller container rather than a view, so its
            // panes and its divider share one safe area and the rule starts under the toolbar.
            DetailSplitView(
                app: app,
                isInspectorPresented: isInspectorPresented,
                animated: !reduceMotion
            )
                // The toolbar's `+` is there only while the sidebar is not, so the column that
                // owns starting work owns it alone whenever it is on screen. The flag is this
                // binding rather than anything read off the window, because this is what actually
                // decides whether the first column is drawn: the menu item below writes it, and
                // AppKit's own sidebar toggle writes it back through the binding. That second
                // half is the one worth measuring, and it was: driving that button through the
                // running app's accessibility tree, which is the channel a real click ends up in,
                // folds the pane away and the `+` arrives, and driving it again takes both back.
                // See `BloomWindowToolbar.isSidebarCollapsed`.
                .toolbar {
                    BloomWindowToolbar(
                        app: app, isSidebarCollapsed: columnVisibility == .detailOnly
                    )
                }
                // Said here as well as under `navigationTitle` below, and deliberately.
                //
                // The title is declared on the split view and the toolbar is declared on this
                // column, so the two are not the same view, and which of them resolves the default
                // title item is not a thing reading the interface settles. The window came up
                // wearing its name twice once already. Both, until a picture says which one did it.
                .toolbar(removing: .title)
                // The window's search field, on the trailing edge of the toolbar, which is where
                // Finder and Mail publish search on this platform.
                //
                // Which edge it lands on is not this modifier's to say. `SearchFieldPlacement` on
                // macOS offers `automatic`, `toolbar`, `toolbarPrincipal` and `sidebar`, and none
                // of them names an edge: the item is appended after the toolbar's own items and
                // goes wherever the packing leaves it. What puts it at the end is the
                // `ToolbarSpacer` in `BloomWindowToolbar`, and without that it sits against the
                // window's name a third of the way across.
                //
                // `.searchable` rather than the hand built field this replaced, and that is the
                // whole reason it moved. An `NSSearchToolbarItem` is compact at rest, expands over
                // the toolbar when it is focused, draws the system's glass and the system's focus
                // ring, and answers Escape, none of which a `TextField` in a `RoundedRectangle`
                // with a hand drawn stroke ever quite did.
                //
                // `HomeBar` used to argue against exactly this, on the grounds that a field in the
                // toolbar would look like it searched the transcript and the inspector too. That
                // was right while the field was a filter for one list. It searches every workspace
                // on the Mac and the full text of every transcript now, so the objection became
                // the case for it: this belongs to the window rather than to a column. Finding a
                // word in what you are reading is still Cmd+F and still the pane's own, which is
                // Xcode's split. See `FindCommand`.
                .searchable(
                    text: $app.homeFilter.query,
                    placement: .toolbar,
                    prompt: Text("Search")
                )
                .searchFocused($isSearchFocused)
        }
        // As well as heading the toolbar (see BloomApp), the title names the window in the
        // Window menu and in Mission Control, so it is worth setting.
        //
        // It takes an automatic rename straight, with no reveal. A window title is also its entry
        // in the Window menu and its label in Mission Control, and neither of those can be
        // animated: what they would show is one arbitrary frame of a scramble, which is a window
        // called `xqbn hgue` in a menu the user is reading to find it by name.
        // `menuWorkspace` rather than `selectedWorkspace`, so an archived workspace being read
        // names the window as well. It is still not what the inspector keys on, below: naming a
        // window costs nothing, and showing a diff for a worktree that is gone does not.
        .navigationTitle(app.menuWorkspace?.name ?? "Bloom")

        // And then removed from the toolbar again, because `WindowTitleControl` draws the name
        // itself and the window came up wearing it twice.
        //
        // The two titles are not one title drawn twice, they are two different mechanisms, which
        // is why hiding one did not hide the other. `NSWindow.titleVisibility`, which `WindowChrome`
        // sets, governs the title AppKit draws. The line above contributes a title item of
        // SwiftUI's own to the window toolbar, and SwiftUI owns that one: it re-resolves it with
        // the toolbar, so nothing set on the window from the side can take it away.
        // `ToolbarDefaultItemKind.title` is the switch for it, and it is the only one.
        //
        // The title itself stays. It is what the Window menu, Mission Control and the Dock read,
        // and the comment above is the reason it is set at all.
        .toolbar(removing: .title)

        // Marks this scene as the main window, so the menu items that act on a workspace grey out
        // while Settings or a project settings window is key. See `MainWindowFocus`.
        .focusedSceneValue(\.isMainWindowFocused, true)

        // Bottom trailing, out of the way of the sidebar and of the composer's send button.
        .overlay(alignment: .bottomTrailing) {
            if let notice = app.notice {
                NoticeBanner(notice: notice) { app.notice = nil }
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : Motion.pane, value: app.notice)

        .task { await app.bootstrap() }
        // The install ping. Started from here because this is the first moment there is a window
        // and a model, and it keeps a loop of its own from then on rather than living inside this
        // task: Bloom goes on running with its window closed, and a view's task does not. It waits
        // a minute before it does anything at all, so nothing about it is part of a launch. See
        // `InstallPingService`.
        .task { InstallPingService.shared.start(app: app) }
        // Debug builds only, and only when asked for on the command line: raises one of the two
        // Help menu sheets so a capture run can look at it. See `FeedbackPresenter`.
        .task { FeedbackPresenter.shared.presentIfRequested() }
        .sheet(isPresented: $isCreateSheetPresented) {
            CreateWorkspaceSheet(
                initialRepo: createTargetRepo, startsOnPullRequest: createStartsOnPullRequest
            )
        }
        // Send Feedback and Submit a Prompt, raised from the Help menu. Here rather than at the
        // menu item, because a `Commands` body is not a view and cannot present anything, and
        // because what was typed into either of them belongs to the app rather than to the sheet:
        // see `FeedbackPresenter` for why a draft that dies with its sheet is the wrong shape.
        .sheet(item: $feedback.sheet) { sheet in
            switch sheet {
            case .report: FeedbackSheet()
            case .prompt: PromptSubmissionSheet()
            case .reportSent:
                FeedbackSentCard(
                    title: Feedback.Copy.reportSent,
                    detail: Feedback.Copy.reportSentDetail,
                    onDismiss: feedback.close
                )
            case .promptSent:
                FeedbackSentCard(
                    title: Feedback.Copy.promptSent,
                    detail: Feedback.Copy.promptSentDetail,
                    onDismiss: feedback.close
                )
            }
        }
        // The offer to turn a folder into a repository. Presented here rather than at each of the
        // controls that can raise it, because there are five of them across two windows and they
        // all reach it through `AppModel.addRepository`.
        .sheet(item: $projectSetup.request.on(.main)) { request in
            ProjectSetupSheet(request: request) { path in
                Task { await app.finishProjectSetup(path) }
            }
        }
        // This one stays on the window rather than moving to the row that asked for it. It is not
        // presented by a click: `AppModel.archive` runs a git safety check first and only refuses
        // afterwards, and it refuses identically whether the request came from a sidebar context
        // menu, the Workspace menu or a keyboard shortcut. There is no single control it could
        // animate out of, and anchoring it to the sidebar row would lose the refusals that arrive
        // for the selected workspace from the menu bar.
        //
        // The title is fixed rather than "Archive <name>?". Workspace names here are whole
        // sentences ("Show me the technolgies-used-in-this-project"), and a title built from one
        // wraps to two lines of bold text that the eye reads as the warning. The name belongs in
        // the message, where a long one costs nothing.
        .confirmationDialog(
            "Archive this workspace?",
            isPresented: $app.pendingArchive.isPresent(),
            titleVisibility: .visible,
            presenting: app.pendingArchive
        ) { request in
            // The request comes from `presenting:` and is handed straight to the model. Reading
            // `app.pendingArchive` back inside the action is what made Archive do nothing at all:
            // dismissing the dialog clears it before the action's task ever reaches the main
            // actor. See `AppModel.confirmArchive`.
            // The role follows the severity rather than the action, because the action is the
            // same either way. A worktree carrying nothing but a `.env` and a folder of generated
            // types gets a plain button: see `ArchiveRequest.Severity`.
            Button(
                request.confirmLabel, role: request.isDestructive ? .destructive : nil
            ) { confirmArchive(request) }
            // No `.keyboardShortcut(.defaultAction)` on the cancel button, and that is not an
            // oversight. It used to be there, to keep Return off the destructive answer, and it
            // did that by REPLACING the cancel button's own key binding. A `.cancel` role button
            // is what Escape is wired to, so moving Return onto it took Escape off it, and no
            // destructive confirmation in the app could be waved away with the key every Mac user
            // reaches for. Verified on this build: with the modifier gone Escape dismisses, and
            // Return does nothing at all, because a confirmation dialog has no default button
            // unless one is named. Both halves of the rule hold, and the safe answer keeps the
            // key it is supposed to have.
            Button(request.cancelLabel, role: .cancel, action: app.cancelPendingArchive)
        } message: { request in
            // Naming what disappears, rather than asking "are you sure?". Written by
            // `ArchiveRequest` in the core, where it can be tested.
            Text(request.message)
        }
        // The question asked before a session that is still working is closed. On the window for
        // the reason the archive confirmation above is: it is raised from the tab strip's close
        // button and from Cmd+W in the menu bar, and there is no one control both of those could
        // animate out of. See `CloseSessionAlert`.
        .confirmationDialog(
            closeSession.request?.title ?? "",
            isPresented: $closeSession.request.isPresent(),
            titleVisibility: .visible,
            presenting: closeSession.request
        ) { request in
            // The wording answers the question that was asked, which is not always the same
            // question: a conversation can be mid turn, or the only one its workspace has, or
            // both. See `SessionClosure`.
            Button(request.cost.confirmTitle, role: .destructive) { closeSession.confirm() }
            // Escape keeps the conversation. See the archive confirmation above for why no cancel
            // button in this app carries `.keyboardShortcut(.defaultAction)`.
            Button(request.cost.cancelTitle, role: .cancel) { closeSession.cancel() }
        } message: { request in
            Text(request.message)
        }
        // The question asked before a setup script runs. On the window because the three controls
        // that raise it are two menus and a transcript row, and a `Commands` body is not a view
        // and can present nothing. See `SetupRunAlert`.
        .confirmation($setupRun.request) { request in
            Confirmation(
                title: request.question.title,
                message: request.question.message,
                confirmLabel: request.question.confirmLabel,
                cancelLabel: request.question.cancelLabel
            )
        } onConfirm: { request in
            request.model.runSetupAgain()
        }
        // A single OK that does nothing but dismiss is the system default, so the actions builder
        // is deliberately empty rather than spelling one out.
        .alert(
            app.alert?.title ?? "",
            isPresented: $app.alert.isPresent(),
            presenting: app.alert
        ) { _ in
        } message: { alert in
            Text(alert.message)
        }
        .onReceive(OpenWorkspaceNotification.publisher()) { id in
            // Through `open(workspaceID:)` rather than straight into the selection, so an id that
            // has since been archived opens its transcript instead of landing on Home with no
            // explanation. See `AppModel.open(workspaceID:)`.
            Task { await app.open(workspaceID: id) }
        }
        // Shift+Cmd+F, and Cmd+F where nothing in front can find. A `Commands` body is not a view
        // and cannot reach a `@FocusState`, so the menu item posts and this listens.
        //
        // The centre pane goes to Home with it. The field is in the toolbar, so it is on screen
        // while a workspace is open, and a search whose answer is drawn in a pane nobody is
        // looking at would be a field that does nothing.
        .onReceive(NotificationCenter.default.publisher(for: .bloomFocusSearch)) { _ in
            app.selection = .home
            isSearchFocused = true
        }
        // Typing into the field is the same act as pressing the key that focuses it, so it lands
        // in the same place. Only on the way IN: clearing the field must not navigate anywhere,
        // because clearing it is how somebody gets back to the list they were reading.
        //
        // The scope settles here too, because this is where the two sets of chips cross. See
        // `HomeScope.settle`.
        .onChange(of: app.homeFilter.query) { old, new in
            let was = !WorkspaceSearch.needle(old).isEmpty
            let now = !WorkspaceSearch.needle(new).isEmpty
            guard was != now else { return }
            app.homeFilter.scope = HomeScope.settle(app.homeFilter.scope, searching: now)
            if now { app.selection = .home }
        }
        .onReceive(NotificationCenter.default.publisher(for: .bloomToggleSidebar)) { _ in
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
        }
        .onReceive(NotificationCenter.default.publisher(for: .bloomOfferProjectSetup)) { note in
            guard let path = note.object as? String else { return }
            Task { await app.addRepository(at: path) }
        }
        // Opening this window is otherwise a menu item or a gear on a row, neither of which a
        // capture run can press, which left the project settings window with no way of being
        // looked at at all. Named by project, or the first one.
        .onReceive(NotificationCenter.default.publisher(for: .bloomOpenRepoSettings)) { note in
            let named = note.object as? String
            let repo = app.repos.first { $0.name == named } ?? app.repos.first
            guard let repo else { return }
            openWindow(id: RepoSettingsWindow.id, value: repo.id)
        }
        // Debug builds only, and it draws nothing on its own: it is how a capture run gets the
        // window into the state the two busy signals are for. See `Snapshot`.
        .acceptsCaptureRunningState(app)
        .acceptsCaptureNotice(app)
        .onReceive(NotificationCenter.default.publisher(for: .bloomNewWorkspace)) { note in
            createTargetRepo = note.object as? Repo ?? app.selectedWorkspace.flatMap(app.repo(for:))
            createStartsOnPullRequest = note.userInfo?[Notification.bloomPullRequestKey] as? Bool == true
            isCreateSheetPresented = true
        }
        // Makes the workspace the create sheet's terminal mode makes, for a capture run, which
        // cannot choose a mode or press a button. It goes through `createWorkspace` exactly as the
        // sheet does, sea and all, so
        // what is photographed is the real workspace rather than a hand-built row that looks like
        // one. Debug builds only, through the same flag family as `--create-sheet`.
        .onReceive(NotificationCenter.default.publisher(for: .bloomStartTerminalWorkspace)) { note in
            let named = note.object as? String
            let repo = app.repos.first { $0.name == named } ?? app.repos.first
            guard let repo else { return }
            Task { await app.createWorkspace(in: repo, prompt: "", opensWith: .terminal) }
        }
    }

    /// The inspector answers one question, what this workspace's agent changed, so on Home it has
    /// nothing to say. It used to sit there as a 380pt column holding a single "No workspace
    /// selected" glyph, and because its divider hairline is almost invisible on white that glyph
    /// read as a stray mark floating in the middle of the window. Hiding it also hands those
    /// points back to Home's list, which is what keeps a workspace name, its diff counts and its
    /// age on one line without truncating any of them.
    ///
    /// Keyed on `selectedWorkspace` rather than on `selection`, because `DetailColumn` already
    /// falls back to Home when a selected id no longer resolves to a workspace.
    private var isInspectorPresented: Bool {
        app.isInspectorVisible && app.selectedWorkspace != nil
    }

    // MARK: - Actions

    private func confirmArchive(_ request: ArchiveRequest) {
        Task { await app.confirmArchive(request) }
    }
}

extension Notification.Name {
    // The channel that opens a workspace is `OpenWorkspaceNotification`, in the core, and it keeps
    // its own name private so nothing can post an id down it untyped. These two carry no id and
    // are only ever posted by views, so they live here.
    static let bloomToggleSidebar = Notification.Name("bloom.toggleSidebar")
    /// Puts the keyboard in the window's search field. Posted by the Edit menu's Search item and
    /// by Cmd+F falling through, neither of which can reach a `@FocusState` from a `Commands`
    /// body.
    static let bloomFocusSearch = Notification.Name("bloom.focusSearch")
    static let bloomNewWorkspace = Notification.Name("bloom.newWorkspace")
    /// Posted only by `Snapshot`, and only in a debug build. See the handler above.
    static let bloomStartTerminalWorkspace = Notification.Name("bloom.startTerminalWorkspace")
    /// The Workspace menu's Rename, aimed at whichever list is drawing that row.
    ///
    /// A notification rather than a flag on `AppModel`, for the same reason the create sheet is
    /// one: the field belongs to a row inside a list, the list owns the one field that can be open
    /// at a time, and a menu item cannot reach into either. Both lists listen, and each ignores a
    /// workspace it is not drawing, so the post can be made without knowing which is on screen.
    static let bloomRenameWorkspace = Notification.Name("bloom.renameWorkspace")
    /// The File menu's Rename Tab, aimed at the strip that owns the field.
    ///
    /// The same shape as the workspace rename above and for the same reason: the field belongs to
    /// a tab inside a strip, the strip owns the one field that can be open at a time, and a menu
    /// item can reach neither. It carries no id, because unlike the two workspace lists there is
    /// only ever one strip on screen and it renames the tab it has selected.
    static let bloomRenameTab = Notification.Name("bloom.renameTab")
}

extension Notification {
    /// Whether a `bloomNewWorkspace` post wants the sheet opened on the pull request route. Absent
    /// on every other post, which is the ordinary new branch opening.
    static let bloomPullRequestKey = "bloom.newWorkspace.pullRequest"
    /// Which workspace a `bloomRenameWorkspace` post is about, as its raw id.
    static let bloomWorkspaceIDKey = "bloom.workspaceID"
}
