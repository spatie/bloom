import SwiftUI
import BatonCore

/// The window: a real `NavigationSplitView` with a real toolbar.
///
/// This used to be a hand-rolled `HStack` with its own drag handles, which is precisely why the
/// window had no title bar, no toolbar, an opaque sidebar and a hard divider running straight
/// through the traffic lights. `NavigationSplitView` hands all of that back to AppKit: the
/// translucent sidebar material, the sidebar toggle, traffic light placement, unified toolbar
/// integration and remembered column widths. The inspector is an `HSplitView` rather than the
/// platform `.inspector`, for the reason spelled out on the detail column below.
///
/// The columns themselves are `SidebarView` and `DetailColumn`, and the toolbar is
/// `BatonWindowToolbar`. What is left here is only what belongs to the window as a whole: the
/// split view, the inspector, the create sheet, the archive confirmation and the alert.
struct RootView: View {
    @Environment(AppModel.self) private var app

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isCreateSheetPresented = false
    @State private var createTargetRepo: Repo?

    var body: some View {
        @Bindable var app = app

        return NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
            .navigationSplitViewColumnWidth(
                min: 200, ideal: Metrics.sidebarWidth, max: 420
            )
        } detail: {
            // An `HSplitView` rather than `.inspector()`.
            //
            // `.inspector` cannot be used in this window. With it presented, the window is marked
            // as needing another Update Constraints pass on every pass, and AppKit throws "more
            // Update Constraints in Window passes than there are views in the window" within a
            // second of launch. Reproduced with the real inspector, with a bare `Text` inside it,
            // attached to the split view and attached to the detail column, and clean every time
            // the inspector is simply not presented. `HSplitView` is the AppKit split view, so the
            // divider stays native and draggable, and it does not go near the toolbar.
            HSplitView {
                DetailColumn()
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)

                if app.isInspectorVisible {
                    InspectorPane(model: app.selectedModel)
                        .frame(
                            minWidth: 280,
                            idealWidth: Metrics.inspectorWidth,
                            maxWidth: 760,
                            maxHeight: .infinity
                        )
                }
            }
                // The toolbar belongs to the detail column, not to the split view. Attached to
                // the split view, AppKit lays every item out in the sidebar's slice of the
                // toolbar, which is narrow, so everything past the first item falls into the
                // overflow menu. On the detail it gets the whole width right of the sidebar.
                .toolbar { BatonWindowToolbar(app: app) }
        }
        // The window title is hidden in the toolbar (see BatonApp), but it still names the window
        // in the Window menu and in Mission Control, so it is worth setting.
        .navigationTitle(app.selectedWorkspace?.name ?? "Baton")

        .task { await app.bootstrap() }
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
            Button("Keep the workspace", role: .cancel, action: app.cancelPendingArchive)
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
        .onReceive(NotificationCenter.default.publisher(for: .batonOpenWorkspace)) { note in
            if let id = note.object as? String { app.selection = .workspace(id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .batonToggleSidebar)) { _ in
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
        }
        .onReceive(NotificationCenter.default.publisher(for: .batonNewWorkspace)) { note in
            createTargetRepo = note.object as? Repo ?? app.selectedWorkspace.flatMap(app.repo(for:))
            isCreateSheetPresented = true
        }
    }

    // MARK: - Actions

    private func confirmArchive() {
        Task { await app.confirmPendingArchive() }
    }

    /// What the user is about to lose, said as a list rather than as a question.
    ///
    /// Built here rather than in the message builder so the string work is a plain function that
    /// can be read, and changed, without going through a view body.
    private static func losses(in request: ArchiveRequest) -> String {
        var text = "Archiving deletes the worktree at \(request.workspace.path).\n\nThis would lose:\n"
        text += request.report.losses.map { "\u{2022} \($0)" }.joined(separator: "\n")
        if let problem = request.problem {
            text += "\n\n\(problem)"
        }
        return text
    }
}

extension Notification.Name {
    // batonOpenWorkspace is declared in AppChrome.swift, next to the notification delegate that
    // posts it. These two are only ever posted by views, so they live here.
    static let batonToggleSidebar = Notification.Name("baton.toggleSidebar")
    static let batonNewWorkspace = Notification.Name("baton.newWorkspace")
}
