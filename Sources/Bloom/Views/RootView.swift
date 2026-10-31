import AppKit
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
/// split view, the inspector, the archive confirmation and the alert.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow

    @Bindable private var projectSetup = ProjectSetup.shared
    @Bindable private var closeSession = CloseSessionAlert.shared
    @Bindable private var setupRun = SetupRunAlert.shared
    /// The two Help menu sheets, and the drafts typed into them. See `FeedbackPresenter`.
    @Bindable private var feedback = FeedbackPresenter.shared

    @AppStorage(WindowPanePreferences.sidebarVisibleKey) private var isSidebarVisible = true
    private var columnVisibility: NavigationSplitViewVisibility {
        isSidebarVisible ? .all : .detailOnly
    }

    private var columnVisibilityBinding: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { columnVisibility },
            set: { isSidebarVisible = $0 != .detailOnly }
        )
    }
    /// One request for the one sheet attached to this window. Repeated entry points update it in
    /// place, preserving the draft and avoiding a second modal presentation.
    @State private var createWorkspacePresentation = CreateWorkspacePresentation()
    @State private var createWorkspaceResolution: Task<Void, Never>?

    var body: some View {
        @Bindable var app = app

        return windowWiring(
            navigation

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
            // The same, for the search panel, which is otherwise reachable only by a key
            // equivalent and a glyph. See `SearchPanelModel.presentIfRequested`.
            .task { presentSearchPanelIfRequested() }
            .sheet(item: createWorkspaceRequest) { request in
                CreateWorkspaceView(
                    initialRepo: app.repos.first { $0.id == request.repoID },
                    pullRequestRevision: request.pullRequestRevision,
                    startsAsConversation: request.startsAsConversation || app.repos.isEmpty
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
            .confirmation($app.pendingScriptFailure) { request in
                Confirmation(
                    title: request.failure.title,
                    message: request.failure.message,
                    confirmLabel: request.failure.confirmLabel,
                    cancelLabel: request.failure.cancelLabel,
                    alternativeLabel: request.failure.retryLabel
                )
            } onConfirm: { request in
                Task { await app.archiveAnyway(request) }
            } onAlternative: { request in
                Task { await app.retryArchive(request) }
            }
            // A single OK that does nothing but dismiss, which `errorAlert` says why it leaves to
            // the system rather than spelling out.
            .errorAlert(item: $app.alert) { $0.title } message: { $0.message }
            .onReceive(OpenWorkspaceNotification.publisher()) { id in
                // Through `open(workspaceID:)` rather than straight into the selection, so an id that
                // has since been archived opens its transcript instead of landing on Home with no
                // explanation. See `AppModel.open(workspaceID:)`.
                Task { await app.open(workspaceID: id) }
            }
            // Shift+Cmd+F, and Cmd+F where nothing in front can find, are handled in
            // `windowWiring` below, and they open the panel rather than putting a keyboard
            // anywhere in the window.
        )
    }

    private var navigation: some View {
        NavigationSplitView(columnVisibility: columnVisibilityBinding) {
            RootSidebarColumn(isSidebarVisible: $isSidebarVisible)
        } detail: {
            RootDetailColumn(columnVisibility: columnVisibility)
        }
        .containerBackground(.clear, for: .window)
        .toolbar(removing: .title)
    }

    /// Debug builds only. In a method of its own so `body` carries one call rather than a
    /// conditional compilation block, which the type checker in there can do without.
    private func presentSearchPanelIfRequested() {
        #if DEBUG
        SearchPanelModel.shared.presentIfRequested(app: app)
        #endif
    }

    /// The window's notification wiring, in a method rather than in `body`.
    ///
    /// Not tidiness. `body` was one chain of forty-odd modifiers, and the new-project sheet that
    /// used to be among them took it past the type checker's budget: the build fails with "unable
    /// to type-check this expression in reasonable time", which names no cause and points at
    /// whichever line the solver happened to give up on. A method has a signature of its own to
    /// solve against, so the two halves are solved separately.
    ///
    /// A method and not a `ViewModifier`, because half of these handlers write this view's own
    /// `@State` and `@FocusState`, and a modifier is a separate type that can see neither.
    private func windowWiring(_ content: some View) -> some View {
        content
        // The search panel, over the whole window rather than over one column: it reaches every
        // workspace on the Mac and the full text of every transcript, so it belongs to the window.
        .searchPanel(app: app)
        // Shift+Cmd+F, and Cmd+F wherever nothing in front can find. Both have always meant "the
        // whole search", and both open the panel on the Transcripts chip, because what neither of
        // them can be is find-in-place: that is the pane's own and stays there.
        //
        // **Nothing here navigates any more.** This used to set the selection to Home and put the
        // keyboard in the toolbar's field, which is what took the reader off the conversation they
        // were in. The panel opens over the window and closes leaving it exactly where it was.
        .onReceive(NotificationCenter.default.publisher(for: .bloomFocusSearch)) { _ in
            SearchPanelModel.shared.open(scope: .transcripts, app: app)
        }
        // The scope settles when Home's own query moves, because that is where the two sets of
        // chips cross. See `HomeScope.settle`. It no longer navigates: the only thing that writes
        // this query now is the panel's "search Home for this" row, which is already on its way to
        // Home, and clearing it is how somebody gets back to the list they were reading.
        .onChange(of: app.homeFilter.query) { old, new in
            let was = !WorkspaceSearch.needle(old).isEmpty
            let now = !WorkspaceSearch.needle(new).isEmpty
            guard was != now else { return }
            app.homeFilter.scope = HomeScope.settle(app.homeFilter.scope, searching: now)
        }
        .onReceive(NotificationCenter.default.publisher(for: .bloomToggleSidebar)) { _ in
            toggleSidebar()
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
        // The four controls that ask still post, because
        // a `Commands` body cannot reach `openWindow` and the other three have always gone through
        // one door. What that flow does once its button is pressed is its own, which is why
        // nothing is parked here waiting for it to come down: see `StartProjectView.finish`.
        .onReceive(NotificationCenter.default.publisher(for: .bloomNewProject)) { _ in
            openWindow(id: StartProjectWindow.id)
        }
        // The post is still the one door every control goes through. Presentation stays here so
        // every entry point updates the same sheet and repeated asks preserve its draft.
        .onReceive(NotificationCenter.default.publisher(for: .bloomNewWorkspace)) { note in
            presentCreateWorkspace(
                in: note.object as? Repo,
                asksForPullRequest: note.userInfo?[Notification.bloomPullRequestKey] as? Bool == true
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .bloomNewConversationWorkspace)) { _ in
            presentCreateWorkspace(in: nil, asksForPullRequest: false, startsAsConversation: true)
        }
        // Makes the workspace the create sheet's terminal mode makes, for a capture run, which
        // cannot choose a mode or press a button. It goes through `createWorkspace` exactly as that
        // window does, sea and all, so what is photographed is the real workspace rather than a
        // hand-built row that looks like one. Debug builds only, through the same flag family as
        // `--create-sheet`.
        .onReceive(NotificationCenter.default.publisher(for: .bloomStartTerminalWorkspace)) { note in
            let named = note.object as? String
            let repo = app.repos.first { $0.name == named } ?? app.repos.first
            guard let repo else { return }
            Task { await app.createWorkspace(in: repo, prompt: "", opensWith: .terminal) }
        }
    }

    private func toggleSidebar() {
        withAnimation(reduceMotion ? nil : Motion.pane) {
            isSidebarVisible.toggle()
        }
    }

    // MARK: - Actions

    /// Presents the sheet on the named project, or on the project most recently started in.
    /// An ask made while the sheet is already up updates that one request and keeps its draft.
    private func presentCreateWorkspace(
        in repo: Repo?, asksForPullRequest: Bool, startsAsConversation: Bool = false
    ) {
        if createWorkspacePresentation.request != nil {
            createWorkspacePresentation.present(
                repoID: repo?.id, asksForPullRequest: asksForPullRequest,
                startsAsConversation: startsAsConversation
            )
            return
        }

        createWorkspaceResolution?.cancel()
        if let repo {
            createWorkspacePresentation.present(
                repoID: repo.id, asksForPullRequest: asksForPullRequest
            )
            return
        }

        if startsAsConversation || app.repos.isEmpty {
            createWorkspacePresentation.present(
                repoID: nil, startsAsConversation: true
            )
            return
        }

        createWorkspaceResolution = Task {
            let target = await app.recentProjects().first
                ?? app.selectedWorkspace.flatMap(app.repo(for:))
                ?? app.repos.first
            guard !Task.isCancelled else { return }
            createWorkspacePresentation.present(
                repoID: target?.id, asksForPullRequest: asksForPullRequest
            )
        }
    }

    private var createWorkspaceRequest: Binding<CreateWorkspacePresentation.Request?> {
        Binding(
            get: { createWorkspacePresentation.request },
            set: { request in
                guard request == nil else { return }
                createWorkspacePresentation.dismiss()
            }
        )
    }

    private func confirmArchive(_ request: ArchiveRequest) {
        Task { await app.confirmArchive(request) }
    }
}

/// Keeps selection observation below the window's split root. A workspace change should update
/// the row highlight, not rebuild every sidebar row as collateral work for the detail column.
private struct RootSidebarColumn: View {
    @Environment(AppModel.self) private var app
    @Binding var isSidebarVisible: Bool

    private var sidebarTintOpacity: Double {
        let preference = ColourThemePreference.shared
        return preference.glass.tintOpacity(maximum: preference.choice.surfaces.glassTintOpacity ?? 0.4)
    }

    /// What the first column may be dragged out to on the display this window is on, or nil when
    /// there is no room for one at all. See `WindowWidths.sidebarMaximum`.
    private var sidebarCeiling: CGFloat? {
        BloomApp.widths.sidebarMaximum(
            sharing: NSScreen.main?.visibleFrame.width ?? .greatestFiniteMagnitude,
            withInspector: app.isInspectorPresented
        )
    }

    var body: some View {
        SidebarView()
            .routesFileDropsToComposer()
            // Replaced by `SidebarToggleButton`, so it can share glass with New.
            .toolbar(removing: .sidebarToggle)
            .environment(\.isSidebarFolded, !isSidebarVisible)
            .scrollContentBackground(.hidden)
            .background {
                Group {
                    if ColourThemePreference.shared.glass == .off {
                        Palette.surfaceSunken
                    } else {
                        SidebarMaterial(tint: Palette.sidebarGlassTint, opacity: sidebarTintOpacity)
                    }
                }
                .ignoresSafeArea()
            }
            .overlay(alignment: .trailing) {
                Hairline(axis: .vertical).ignoresSafeArea(edges: .top)
            }
            .navigationSplitViewColumnWidth(
                min: BloomApp.sidebarMinimumWidth,
                ideal: Metrics.sidebarWidth,
                max: sidebarCeiling ?? BloomApp.sidebarMinimumWidth
            )
            // A display with no room for a sidebar folds it rather than clipping it. It stays
            // folded when room returns, because unfolding it without being asked rearranges the
            // window behind the user.
            .onChange(of: sidebarCeiling == nil, initial: true) { _, folds in
                if folds { isSidebarVisible = false }
            }
    }
}

/// The selection-sensitive half of the window. Keeping it below `NavigationSplitView` means the
/// sidebar and the window wiring are not reevaluated when this retained pane changes identity.
private struct RootDetailColumn: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let columnVisibility: NavigationSplitViewVisibility

    var body: some View {
        DetailSplitView(
            app: app,
            isInspectorPresented: app.isInspectorPresented,
            animated: !reduceMotion
        )
        .background { Palette.sidebar.ignoresSafeArea() }
        .toolbar {
            BloomWindowToolbar(app: app, isSidebarFolded: columnVisibility == .detailOnly)
        }
        // `WindowTitleControl` owns the visible title item. `WindowTitle` sets the NSWindow title
        // used by the Window menu, Mission Control and saved window state.
        .toolbar(removing: .title)
    }
}

extension Notification.Name {
    // The channel that opens a workspace is `OpenWorkspaceNotification`, in the core, and it keeps
    // its own name private so nothing can post an id down it untyped. These two carry no id and
    // are only ever posted by views, so they live here.
    static let bloomToggleSidebar = Notification.Name("bloom.toggleSidebar")
    /// Opens the search panel on the Transcripts chip. Posted by the Edit menu's Search item and
    /// by Cmd+F falling through, both of which mean "the whole search" rather than find-in-place.
    ///
    /// The name is older than the panel and is kept rather than churned: it is the same door, and
    /// what it used to open was a field in the toolbar. It no longer puts a keyboard anywhere in
    /// the window, which is the defect the panel exists to fix.
    static let bloomFocusSearch = Notification.Name("bloom.focusSearch")
    /// Asks for the create sheet. Still a notification rather than direct presentation at each of
    /// the four controls that can ask, because which project is meant depends on what this window
    /// has selected, and because the four have always behaved identically by going through one
    /// door. See `presentCreateWorkspace`.
    static let bloomNewWorkspace = Notification.Name("bloom.newWorkspace")
    static let bloomNewConversationWorkspace = Notification.Name("bloom.newConversationWorkspace")
    /// Opens the window that starts a project. A notification for the same reason the create
    /// window is opened by one: the sidebar's `+`, Home's empty state, the toolbar and a
    /// `Commands` body can none of them reach `openWindow`, and this is where the receiver that
    /// can has always been. The name is the old one twice over, because what it raises is still
    /// the same surface: `StartProjectView` absorbed the second door rather than replacing the
    /// first, and it stopped being a sheet without changing what it asks.
    static let bloomNewProject = Notification.Name("bloom.newProject")
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
    /// Whether a `bloomNewWorkspace` post wants the window opened on the pull request route. Absent
    /// on every other post, which is the ordinary new branch opening.
    static let bloomPullRequestKey = "bloom.newWorkspace.pullRequest"
    /// Which workspace a `bloomRenameWorkspace` post is about, as its raw id.
    static let bloomWorkspaceIDKey = "bloom.workspaceID"
}
