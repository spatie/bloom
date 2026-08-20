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
    /// The two Help menu sheets, and the drafts typed into them. See `FeedbackPresenter`.
    @Bindable private var feedback = FeedbackPresenter.shared

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isCreateSheetPresented = false
    @State private var createTargetRepo: Repo?

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
        }
        // The window title is hidden in the toolbar (see BloomApp), but it still names the window
        // in the Window menu and in Mission Control, so it is worth setting.
        //
        // It takes an automatic rename straight, with no reveal. A window title is also its entry
        // in the Window menu and its label in Mission Control, and neither of those can be
        // animated: what they would show is one arbitrary frame of a scramble, which is a window
        // called `xqbn hgue` in a menu the user is reading to find it by name.
        // `menuWorkspace` rather than `selectedWorkspace`, so an archived workspace being read
        // names the window as well. It is still not what the inspector keys on, below: naming a
        // window costs nothing, and showing a diff for a worktree that is gone does not.
        .navigationTitle(app.menuWorkspace?.name ?? "Bloom")

        // Marks this scene as the main window, so the menu items that act on a workspace grey out
        // while Settings or a project settings window is key. See `MainWindowFocusKey`.
        .focusedSceneValue(\.isMainWindowFocused, true)

        // Bottom trailing, out of the way of the sidebar and of the composer's send button.
        .overlay(alignment: .bottomTrailing) {
            if let notice = app.notice {
                NoticeBanner(notice: notice) { app.notice = nil }
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: app.notice)

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
        // The terminal panel lives at the bottom of the inspector now, so anything that asks for
        // the panel has to bring the inspector with it. Without this, Toggle Bottom Panel from the
        // menu bar while the inspector is closed does nothing at all.
        .onChange(of: app.isBottomPanelVisible) {
            if app.isBottomPanelVisible { app.isInspectorVisible = true }
        }
        .sheet(isPresented: $isCreateSheetPresented) {
            CreateWorkspaceSheet(initialRepo: createTargetRepo)
        }
        // Send Feedback and Submit a Prompt, raised from the Help menu. Here rather than at the
        // menu item, because a `Commands` body is not a view and cannot present anything, and
        // because what was typed into either of them belongs to the app rather than to the sheet:
        // see `FeedbackPresenter` for why a draft that dies with its sheet is the wrong shape.
        .sheet(item: $feedback.sheet) { sheet in
            switch sheet {
            case .report: FeedbackSheet()
            case .prompt: PromptSubmissionSheet()
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
            Button(Self.confirmLabel(for: request), role: .destructive) { confirmArchive(request) }
            // No `.keyboardShortcut(.defaultAction)` on the cancel button, and that is not an
            // oversight. It used to be there, to keep Return off the destructive answer, and it
            // did that by REPLACING the cancel button's own key binding. A `.cancel` role button
            // is what Escape is wired to, so moving Return onto it took Escape off it, and no
            // destructive confirmation in the app could be waved away with the key every Mac user
            // reaches for. Verified on this build: with the modifier gone Escape dismisses, and
            // Return does nothing at all, because a confirmation dialog has no default button
            // unless one is named. Both halves of the rule hold, and the safe answer keeps the
            // key it is supposed to have.
            Button("Keep the workspace", role: .cancel, action: app.cancelPendingArchive)
        } message: { request in
            // Naming what disappears, rather than asking "are you sure?".
            Text(Self.losses(in: request))
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
        ) { _ in
            Button("Close anyway", role: .destructive) { closeSession.confirm() }
            // Escape keeps the session. See the archive confirmation above for why no cancel
            // button in this app carries `.keyboardShortcut(.defaultAction)`.
            Button("Keep working", role: .cancel) { closeSession.cancel() }
        } message: { _ in
            Text(CloseSessionAlert.message)
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
        .onReceive(NotificationCenter.default.publisher(for: .bloomOpenWorkspace)) { note in
            // Through `open(workspaceID:)` rather than straight into the selection, so an id that
            // has since been archived opens its transcript instead of landing on Home with no
            // explanation. See `AppModel.open(workspaceID:)`.
            if let id = note.object as? String { Task { await app.open(workspaceID: id) } }
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
        .onReceive(NotificationCenter.default.publisher(for: .bloomNewWorkspace)) { note in
            createTargetRepo = note.object as? Repo ?? app.selectedWorkspace.flatMap(app.repo(for:))
            isCreateSheetPresented = true
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

    /// The destructive button's label, which only promises a loss when there is one.
    ///
    /// This dialog is now raised by the sidebar row's hover button as well, which asks every time
    /// precisely because it appears under the pointer unbidden. Telling somebody they are about
    /// to "lose that work" when the worktree is clean is the fastest way to teach them that this
    /// dialog exaggerates.
    private static func confirmLabel(for request: ArchiveRequest) -> String {
        request.reasons.isEmpty && request.problem == nil ? "Archive" : "Archive and lose that work"
    }

    /// What the user is about to lose, said as a list rather than as a question.
    ///
    /// Built here rather than in the message builder so the string work is a plain function that
    /// can be read, and changed, without going through a view body.
    ///
    /// A confirmation that only asks "are you sure?" is one people learn to click through, so
    /// this one always says what archiving does to this particular workspace, and adds the list
    /// only when there is something on it. `ArchiveRequest.reasons` puts the agent mid turn
    /// first, because that is the work that is not in git yet.
    private static func losses(in request: ArchiveRequest) -> String {
        // The worktree's path used to open this message and it took five wrapped lines of a
        // narrow dialog to say something the name above it had already said. What has to be read
        // here is the list, so the path is gone and the name is what identifies the workspace,
        // which is what it does everywhere else in the app.
        var text = "\u{201C}\(request.workspace.name)\u{201D}\n\n"
        text += "The worktree is deleted and the branch is "
        text += request.hazards.isDeletingBranch ? "deleted too." : "kept."
        text += " The workspace moves to Archived."
        let reasons = request.reasons
        if !reasons.isEmpty {
            text += "\n\nThis would lose:\n"
            text += reasons.map { "\u{2022} \($0)" }.joined(separator: "\n")
        }
        if let problem = request.problem {
            text += "\n\n\(problem)"
        }
        return text
    }
}

extension Notification.Name {
    // bloomOpenWorkspace is declared in BloomAppDelegate.swift, next to the delegate that posts
    // it. These two are only ever posted by views, so they live here.
    static let bloomToggleSidebar = Notification.Name("bloom.toggleSidebar")
    static let bloomNewWorkspace = Notification.Name("bloom.newWorkspace")
}
