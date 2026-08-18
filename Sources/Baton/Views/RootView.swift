import SwiftUI
import BatonCore

/// The window: a real `NavigationSplitView` with a real toolbar.
///
/// This used to be a hand-rolled `HStack` with its own drag handles, which is precisely why the
/// window had no title bar, no toolbar, an opaque sidebar and a hard divider running straight
/// through the traffic lights. `NavigationSplitView` hands all of that back to AppKit: the
/// translucent sidebar material, the sidebar toggle, traffic light placement, unified toolbar
/// integration and remembered column widths. The inspector is the platform `.inspector`, so it
/// resizes and collapses the way every other Mac inspector does.
struct RootView: View {
    @Environment(AppModel.self) private var app

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isCreateSheetPresented = false
    @State private var createTargetRepo: Repo?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(
                    min: 200, ideal: Metrics.sidebarWidth, max: 420
                )
        } detail: {
            center
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                // The toolbar belongs to the detail column, not to the split view. Attached to
                // the split view, AppKit lays every item out in the sidebar's slice of the
                // toolbar, which is narrow, so everything past the first item falls into the
                // overflow menu. On the detail it gets the whole width right of the sidebar.
                .toolbar { toolbar }
        }
        // The window title is hidden in the toolbar (see BatonApp), but it still names the window
        // in the Window menu and in Mission Control, so it is worth setting.
        .navigationTitle(windowTitle)
        .inspector(isPresented: isInspectorVisible) { inspector }
        .task { await app.bootstrap() }
        .sheet(isPresented: $isCreateSheetPresented) {
            CreateWorkspaceSheet(initialRepo: createTargetRepo)
        }
        .confirmationDialog(
            "Archive \(app.pendingArchive?.workspace.name ?? "")?",
            isPresented: archiveBinding,
            titleVisibility: .visible,
            presenting: app.pendingArchive
        ) { request in
            Button("Archive and lose that work", role: .destructive) {
                Task { await app.confirmPendingArchive() }
            }
            Button("Keep the workspace", role: .cancel) {
                app.cancelPendingArchive()
            }
        } message: { request in
            // Naming what disappears, rather than asking "are you sure?". The confirmation only
            // exists because there is something specific to lose, so it should say what.
            Text(
                "Archiving deletes the worktree at \(request.workspace.path).\n\nThis would lose:\n"
                + request.report.losses.map { "\u{2022} \($0)" }.joined(separator: "\n")
            )
        }
        .alert(item: alertBinding) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
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

    // MARK: - Columns

    @ViewBuilder
    private var center: some View {
        if !app.isLoaded {
            LoadingView()
        } else {
            switch app.selection {
            case .home:
                HomeView()
            case .search:
                SearchView()
            case .workspace:
                if let workspace = app.selectedWorkspace {
                    // `existingModel` rather than `model(for:)`: creating one here would mutate
                    // observable state during the render pass. The selection setter has already
                    // made it.
                    if let model = app.existingModel(for: workspace.id) {
                        WorkspaceDetailView(model: model)
                    } else {
                        LoadingView()
                    }
                } else {
                    HomeView()
                }
            }
        }
    }

    @ViewBuilder
    private var inspector: some View {
        if let model = app.selectedModel {
            InspectorView(model: model)
                // Rebuilt per workspace, so a diff selection never leaks across a switch.
                .id(model.workspace.id)
                .inspectorColumnWidth(min: 280, ideal: Metrics.inspectorWidth, max: 760)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            // A split button: the common case is one click, and the folder picker that used to
            // hide in the account row lives behind the arrow.
            Menu {
                Button("New Workspace") { presentCreate(in: nil) }
                    .disabled(app.repos.isEmpty)
                Button("Add Project Folder\u{2026}") { addProject() }
                Divider()
                Button("Refresh Changes") { Task { await app.refreshDiffStats() } }
            } label: {
                Label("New workspace", systemImage: "plus")
            } primaryAction: {
                if app.repos.isEmpty { addProject() } else { presentCreate(in: nil) }
            }
            .help("Start a workspace")
        }

        // Always present, even on Home, because an empty principal item collapses the flexible
        // space that pins the trailing toggles to the right of the toolbar, and controls that
        // move as you navigate are worse than a redundant word.
        ToolbarItem(placement: .principal) {
            title
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: isBottomPanelVisible) {
                Label("Terminal panel", systemImage: "rectangle.bottomthird.inset.filled")
            }
            .toggleStyle(.button)
            .disabled(app.selectedModel == nil)
            .help("Show the terminal panel")

            Toggle(isOn: isInspectorVisible) {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .toggleStyle(.button)
            .disabled(app.selectedModel == nil)
            .help("Show the changed files")
        }
    }

    /// What the toolbar says you are looking at: the project, the workspace and the branch you
    /// are about to push. Those are the three facts people keep needing, and the toolbar is where
    /// a Mac app puts them.
    @ViewBuilder
    private var title: some View {
        if let workspace = app.selectedWorkspace {
            HStack(spacing: 6) {
                if let repo = app.repo(for: workspace) {
                    Circle()
                        .fill(Color(hexString: repo.accent))
                        .frame(width: Self.accentDot, height: Self.accentDot)
                    Text(repo.name)
                        .font(Typo.label)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(Typo.micro)
                        .foregroundStyle(Palette.textTertiary)
                }

                Text(workspace.name)
                    .font(Typo.labelEmphasis)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)

                Chip(
                    text: workspace.branch,
                    systemImage: "arrow.triangle.branch",
                    monospaced: true
                )
                .help(workspace.branch)
            }
            .fixedSize()
        } else {
            Text(app.selection == .search ? "Search" : "Home")
                .font(Typo.labelEmphasis)
                .foregroundStyle(Palette.textSecondary)
        }
    }

    /// The one measurement here that no semantic constant covers: a colour swatch small enough to
    /// read as a marker rather than a control.
    private static let accentDot: CGFloat = 8

    private var windowTitle: String {
        app.selectedWorkspace?.name ?? "Baton"
    }

    // MARK: - Bindings

    /// The inspector belongs to the selected workspace, so its visibility is stored there rather
    /// than in the window. Home and Search have nothing to inspect and read as false.
    private var isInspectorVisible: Binding<Bool> {
        Binding(
            get: { app.selectedModel?.isInspectorVisible ?? false },
            set: { visible in app.selectedModel?.isInspectorVisible = visible }
        )
    }

    private var isBottomPanelVisible: Binding<Bool> {
        Binding(
            get: { app.selectedModel?.isBottomPanelVisible ?? false },
            set: { visible in app.selectedModel?.isBottomPanelVisible = visible }
        )
    }

    /// Dismissing the dialog by any route must clear the request, or a refused archive would sit
    /// there and re-present itself on the next redraw.
    private var archiveBinding: Binding<Bool> {
        Binding(
            get: { app.pendingArchive != nil },
            set: { presented in if !presented { app.cancelPendingArchive() } }
        )
    }

    private var alertBinding: Binding<BatonAlert?> {
        Binding(
            get: { app.alert },
            set: { newValue in
                let model = app
                model.alert = newValue
            }
        )
    }

    // MARK: - Actions

    /// Every entry point goes through the same notification so the sheet behaves identically
    /// whether it came from the toolbar, the sidebar, Home or the menu bar.
    private func presentCreate(in repo: Repo?) {
        NotificationCenter.default.post(name: .batonNewWorkspace, object: repo)
    }

    private func addProject() {
        guard let path = ProjectFolderPicker.choose() else { return }
        Task { await app.addRepository(at: path) }
    }
}

extension Notification.Name {
    // batonOpenWorkspace is declared in AppChrome.swift, next to the notification delegate that
    // posts it. These two are only ever posted by views, so they live here.
    static let batonToggleSidebar = Notification.Name("baton.toggleSidebar")
    static let batonNewWorkspace = Notification.Name("baton.newWorkspace")
}
