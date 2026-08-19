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
                .toolbar { BloomWindowToolbar(app: app) }
        }
        // The window title is hidden in the toolbar (see BloomApp), but it still names the window
        // in the Window menu and in Mission Control, so it is worth setting.
        //
        // It takes an automatic rename straight, with no reveal. A window title is also its entry
        // in the Window menu and its label in Mission Control, and neither of those can be
        // animated: what they would show is one arbitrary frame of a scramble, which is a window
        // called `xqbn hgue` in a menu the user is reading to find it by name.
        .navigationTitle(app.selectedWorkspace?.name ?? "Bloom")

        // Bottom trailing, out of the way of the sidebar and of the composer's send button.
        .overlay(alignment: .bottomTrailing) {
            if let notice = app.notice {
                NoticeBanner(notice: notice) { app.notice = nil }
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: app.notice)

        .task { await app.bootstrap() }
        // The terminal panel lives at the bottom of the inspector now, so anything that asks for
        // the panel has to bring the inspector with it. Without this, Toggle Bottom Panel from the
        // menu bar while the inspector is closed does nothing at all.
        .onChange(of: app.isBottomPanelVisible) {
            if app.isBottomPanelVisible { app.isInspectorVisible = true }
        }
        .sheet(isPresented: $isCreateSheetPresented) {
            CreateWorkspaceSheet(initialRepo: createTargetRepo)
        }
        // This one stays on the window rather than moving to the row that asked for it. It is not
        // presented by a click: `AppModel.archive` runs a git safety check first and only refuses
        // afterwards, and it refuses identically whether the request came from a sidebar context
        // menu, the Workspace menu or a keyboard shortcut. There is no single control it could
        // animate out of, and anchoring it to the sidebar row would lose the refusals that arrive
        // for the selected workspace from the menu bar.
        .confirmationDialog(
            "Archive \(app.pendingArchive?.workspace.name ?? "")?",
            isPresented: $app.pendingArchive.isPresent(),
            titleVisibility: .visible,
            presenting: app.pendingArchive
        ) { _ in
            Button("Archive and lose that work", role: .destructive, action: confirmArchive)
            // Return keeps the workspace, for the reason `CloseSessionAlert` gives for the same
            // choice: the destructive answer should cost a deliberate click, not the key your hand
            // is already on. Without this the dialog opens with "Archive and lose that work" as the
            // default, so Cmd+Delete and then Return destroys a worktree without a word being read.
            Button("Keep the workspace", role: .cancel, action: app.cancelPendingArchive)
                .keyboardShortcut(.defaultAction)
        } message: { request in
            // Naming what disappears, rather than asking "are you sure?". The confirmation only
            // exists because there is something specific to lose, so it should say what.
            Text(Self.losses(in: request))
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
            if let id = note.object as? String { app.selection = .workspace(id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .bloomToggleSidebar)) { _ in
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
        }
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

    private func confirmArchive() {
        Task { await app.confirmPendingArchive() }
    }

    /// What the user is about to lose, said as a list rather than as a question.
    ///
    /// Built here rather than in the message builder so the string work is a plain function that
    /// can be read, and changed, without going through a view body.
    /// Names the specific reason this sheet appeared.
    ///
    /// A confirmation that only asks "are you sure?" is one people learn to click through, and
    /// this one is now rare enough to be worth reading: the routine archive, with a clean
    /// worktree and nothing running, no longer raises it at all. `ArchiveRequest.reasons` puts the
    /// agent mid turn first, because that is the work that is not in git yet.
    private static func losses(in request: ArchiveRequest) -> String {
        var text = "Archiving deletes the worktree at \(request.workspace.path)."
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
