import SwiftUI
import BatonCore

/// The left column: where you can go, every project with its workspaces, and a status bar that
/// stays put.
///
/// A real `List` with `.listStyle(.sidebar)`, not a `ScrollView` over a `LazyVStack`. The list
/// brings the source list treatment that was previously hand-drawn and always slightly wrong:
/// AppKit selection (accent when the window is key, grey when it is not), disclosure triangles on
/// section headers, the standard row insets, and keyboard navigation between rows.
///
/// There is no account row. Baton is local and single user, so a row naming the logged-in Mac
/// user said nothing, and on macOS `Menu { } label: { }` with `.borderlessButton` throws the
/// custom label away and draws only the indicator, which is why it rendered as a lone letter.
struct SidebarView: View {
    @Environment(AppModel.self) private var app

    @State private var renaming: String?
    @State private var filter: SidebarFilter = .all

    /// What the list itself thinks is selected. See the `onChange` pair below for why this is not
    /// bound straight to the model.
    @State private var listSelection: SidebarSelection?

    /// The grouped, filtered, sorted list the rows are drawn from.
    ///
    /// Derived state held in `@State` rather than recomputed in `body`, with the three inputs it
    /// depends on invalidating it explicitly below. See `SidebarRepoGroup` for why.
    @State private var groups: [SidebarRepoGroup] = []

    var body: some View {
        List(selection: $listSelection) {
            Section {
                navRow(.home, title: "Home", icon: "house")
                navRow(.search, title: "Search", icon: "magnifyingglass")
            }

            ForEach(groups) { group in
                RepoSection(
                    repo: group.repo,
                    rows: group.workspaces,
                    isFiltered: filter != .all,
                    renaming: $renaming,
                    onCreateWorkspace: presentCreate
                )
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if app.repos.isEmpty, app.isLoaded {
                noProjects
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarStatusBar(filter: $filter)
        }
        .onChange(of: app.repos, initial: true) { _, _ in regroup() }
        .onChange(of: app.workspaces) { _, _ in regroup() }
        .onChange(of: filter) { _, _ in regroup() }
        .onChange(of: listSelection) { _, _ in commitSelection() }
        // Moving off a row has to close whatever field was open on it, or the rename would carry
        // on editing a workspace that is no longer on screen.
        .onChange(of: app.selection, initial: true) { _, target in
            renaming = nil
            listSelection = target
        }
    }

    private func regroup() {
        groups = SidebarRepoGroup.build(
            repos: app.repos, workspaces: app.workspaces, filter: filter
        )
    }

    // MARK: - Selection

    /// The list works in optionals because clicking empty space deselects, and Baton always has
    /// somewhere to be, so an empty selection is put back rather than passed on.
    ///
    /// Putting it back is the whole reason the list is not bound straight to the model through a
    /// hand-made binding. A binding whose setter drops `nil` looks like it refuses the
    /// deselection, but the table has already cleared its own highlight by then and nothing
    /// invalidates it again, so the row went blank while the detail pane carried on showing the
    /// workspace. Writing the old value back into the list's own state is what redraws it.
    ///
    /// Running here rather than in a binding setter also keeps the model write out of the table's
    /// selection callback, which is what AppKit means by a reentrant delegate operation.
    private func commitSelection() {
        guard let listSelection else {
            listSelection = app.selection
            return
        }
        app.selection = listSelection
    }

    private func navRow(_ target: SidebarSelection, title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .tag(target)
    }

    // MARK: - Empty

    private var noProjects: some View {
        ContentUnavailableView {
            Label("No projects yet", systemImage: "folder.badge.plus")
        } description: {
            Text("Point Baton at a git repository to start running agents in it.")
        } actions: {
            Button("Add a Folder", action: addProject)
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Actions

    /// The create sheet lives in `RootView`, so every entry point (the toolbar, the repo header's
    /// `+`, the menu bar command) goes through one notification and behaves identically.
    private func presentCreate(in repo: Repo?) {
        renaming = nil
        NotificationCenter.default.post(name: .batonNewWorkspace, object: repo)
    }

    private func addProject() {
        guard let path = ProjectFolderPicker.choose() else { return }
        Task { await app.addRepository(at: path) }
    }
}
