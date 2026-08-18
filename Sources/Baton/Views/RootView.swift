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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Survives relaunch, because an inspector that forgets how wide you made it is worse than
    /// one that cannot be resized at all.
    @AppStorage("inspector.width") private var inspectorWidth: Double = Metrics.inspectorWidth
    /// The detail column's own width, which is the window minus the sidebar. The inspector's
    /// ceiling comes from this, so it has to be measured rather than assumed.
    @State private var detailWidth: Double = 0
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
            // An `HStack` and our own divider, rather than `.inspector()` or `HSplitView`.
            //
            // `.inspector` cannot be used in this window. With it presented, the window is marked
            // as needing another Update Constraints pass on every pass, and AppKit throws "more
            // Update Constraints in Window passes than there are views in the window" within a
            // second of launch. Reproduced with the real inspector, with a bare `Text` inside it,
            // attached to the split view and attached to the detail column, and clean every time
            // the inspector is simply not presented.
            //
            // `HSplitView` was the next attempt and it did not crash, but it is an AppKit split
            // view that draws its divider down its whole bounds while the SwiftUI content inside
            // each pane respects the safe area. Under a unified toolbar that put a hard rule
            // through the title. A divider we lay out ourselves sits in the same safe area as the
            // panes, so it starts below the toolbar where a pane boundary belongs.
            HStack(spacing: 0) {
                DetailColumn()
                    .frame(
                        minWidth: DetailColumnLayout.minimum,
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )

                if app.isInspectorVisible {
                    // The divider and the pane move as one, because the boundary is part of the
                    // pane rather than a thing the detail column keeps when the pane leaves.
                    HStack(spacing: 0) {
                        InspectorDivider(width: $inspectorWidth, available: detailWidth)
                        InspectorPane(model: app.selectedModel)
                            .frame(width: fittedInspectorWidth)
                    }
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .trailing))
                }
            }
            // Keyed on the visibility alone, so the width the pane is dragged to and the width it
            // is clamped to as the window narrows both stay instant. A pane that eased its way
            // after the pointer would feel broken, and animating on every layout is exactly the
            // churn that used to crash this window.
            .animation(reduceMotion ? nil : Motion.pane, value: app.isInspectorVisible)
            // The stored width is what the user asked for, `fittedInspectorWidth` is what fits.
            // Measured on every layout rather than only while dragging, so narrowing the window
            // narrows the inspector instead of squeezing the sidebar out of view.
            .onGeometryChange(for: Double.self) { proxy in
                proxy.size.width
            } action: { detailWidth = $0 }
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

    /// The stored width, capped at what is left once the detail column keeps its minimum. The
    /// stored value is deliberately not rewritten, so widening the window restores the width the
    /// user chose rather than leaving it where a narrow window clamped it.
    private var fittedInspectorWidth: Double {
        guard detailWidth > 0 else { return inspectorWidth }
        let ceiling = detailWidth - DetailColumnLayout.minimum - Metrics.spacingWide
        return min(inspectorWidth, max(InspectorDivider.minimum, ceiling))
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
