import SwiftUI
import BloomCore

/// The left column: where you can go, every project with its workspaces, and a status bar that
/// stays put.
///
/// A real `List` with `.listStyle(.sidebar)`, not a `ScrollView` over a `LazyVStack`. The list
/// brings the source list treatment that was previously hand-drawn and always slightly wrong:
/// AppKit selection (accent when the window is key, grey when it is not), the standard row
/// insets, and keyboard navigation between rows.
///
/// It does bring a disclosure control on a section header, and that is why `RepoSection` uses a
/// plain `Section`. Hand the list an `isExpanded` binding and it draws a chevron of its own at the
/// trailing end of the header, under the pointer only, which on a project header landed past the
/// gear and the `+` and said what the header's own leading chevron already said. A comment here
/// used to claim the opposite, from a capture taken with the pointer nowhere near the window.
///
/// There is no account row. Bloom is local and single user, so a row naming the logged-in Mac
/// user said nothing, and on macOS `Menu { } label: { }` with `.borderlessButton` throws the
/// custom label away and draws only the indicator, which is why it rendered as a lone letter.
struct SidebarView: View {
    @Environment(AppModel.self) private var app
    /// The window's undo manager. Only a view can see it, and `AppModel` is where the archive
    /// that wants it happens, so the sidebar hands it over. Any view in the window would do; this
    /// is the one that is always on screen.
    @Environment(\.undoManager) private var undoManager

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

            // A plain row rather than a `Section` header, because the things it heads are
            // themselves sections and a list cannot nest one inside another. It carries no tag
            // and refuses selection, so it stays a label. Home and Search keep their own section
            // above it, which is what stops them reading as the first two projects.
            SidebarProjectsHeader(onAddProject: addProject)
                .selectionDisabled()
                .listRowSeparator(.hidden)

            ForEach(groups) { group in
                RepoSection(
                    repo: group.repo,
                    rows: group.workspaces,
                    isFiltered: filter != .all,
                    hasUnreadWork: group.hasUnreadWork,
                    renaming: $renaming,
                    onCreateWorkspace: presentCreate
                )
            }
        }
        // The list draws its own selection and its own row height, and both are left to it.
        //
        // Selection: this is the one list in the window with the system's source list treatment,
        // and its highlight follows the user's own accent, dims when the list loses the keyboard
        // and inverts the row's text for us through `backgroundProminence`, which `WorkspaceRow`
        // reads. Repainting it in Bloom's teal would buy consistency with the inspector at the
        // cost of all three, and would make this the only Mac sidebar that ignores the accent the
        // user chose in System Settings. A source list selection is a system affordance, not
        // branding. The brand is everywhere else.
        //
        // Row height: 32 points, where `Metrics.rowHeight` is 28 and the reference render is 28
        // as well. It is not ours to set. `listRowInsets`, an explicit `frame(height:)` on the
        // row, `defaultMinListRowHeight` and `controlSize` were each tried and each captured, and
        // all four left the pitch at exactly 32; `listRowInsets(leading:)` did not even move the
        // rows sideways. Reaching 28 means giving up `.listStyle(.sidebar)`, and with it the
        // selection above, keyboard navigation and the standard insets. Four points is not worth
        // that. What was in reach was making the rhythm EVEN, which is what `RepoSection` spends
        // its header padding on.
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
        // Not observed state, so this write invalidates nothing and is safe from an update.
        .onChange(of: undoManager, initial: true) { _, manager in
            app.undoManager = manager
        }
    }

    private func regroup() {
        groups = SidebarRepoGroup.build(
            repos: app.repos, workspaces: app.workspaces, filter: filter
        )
    }

    // MARK: - Selection

    /// The list works in optionals because clicking empty space deselects, and Bloom always has
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
            Text("Point Bloom at a git repository to start running agents in it.")
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
        NotificationCenter.default.post(name: .bloomNewWorkspace, object: repo)
    }

    private func addProject() {
        Task { await app.addProjectByAsking() }
    }
}
