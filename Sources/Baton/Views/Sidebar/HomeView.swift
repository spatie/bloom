import SwiftUI
import BatonCore

/// The centre pane when nothing is selected.
///
/// Home answers one question: what is going on across every project right now. It is grouped by
/// project rather than sorted purely by time, because a developer thinks in projects first and
/// the grouping is what makes a screen of twenty workspaces readable.
struct HomeView: View {
    @Environment(AppModel.self) private var app

    @State private var hovered: String?

    /// The recent workspaces per project, sorted once when the data changes rather than on every
    /// redraw. Home is on screen while agents are running, so `body` runs constantly.
    @State private var sections: [SidebarRepoGroup] = []

    /// Enough to fill the grid without turning Home into a second sidebar.
    private static let perProject = 9

    var body: some View {
        Group {
            if app.repos.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.windowBackground)
        .onChange(of: app.repos, initial: true) { _, _ in rebuild() }
        .onChange(of: app.workspaces) { _, _ in rebuild() }
    }

    // MARK: - Populated

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HomeWelcomeHeader(
                    greeting: greeting,
                    summary: summary,
                    onCreateWorkspace: { requestWorkspace(in: nil) }
                )

                ForEach(sections) { section in
                    HomeRepoSection(
                        repo: section.repo,
                        workspaces: section.workspaces,
                        hovered: $hovered,
                        onCreateWorkspace: { requestWorkspace(in: $0) },
                        onSelect: select
                    )
                }
            }
            .padding(28)
            .frame(maxWidth: 1_100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var greeting: String {
        let name = NSFullUserName().components(separatedBy: .whitespaces).first ?? ""
        return name.isEmpty ? "Welcome back" : "Welcome back, \(name)"
    }

    private var summary: String {
        let active = app.workspaces.count
        let unread = app.workspaces.count(where: \.unread)
        if active == 0 { return "No workspaces yet. Start one and an agent gets to work." }
        let workspaces = active == 1 ? "1 workspace" : "\(active) workspaces"
        if unread == 0 { return "\(workspaces) across \(app.repos.count) projects." }
        return "\(workspaces), \(unread) waiting to be read."
    }

    // MARK: - Empty

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Add your first project", systemImage: "folder.badge.plus")
        } description: {
            Text("Point Baton at a git repository. Every workspace you start gets its own worktree and its own agent, so they never step on each other.")
        } actions: {
            Button("Choose a folder", systemImage: "folder", action: addProject)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Derived

    /// Most recently active first, capped, and only for projects that have anything to show.
    private func rebuild() {
        sections = app.repos.compactMap { repo in
            let recent = app.workspaces
                .filter { $0.repoID == repo.id }
                .sorted { $0.lastActivityAt > $1.lastActivityAt }
                .prefix(Self.perProject)
            guard !recent.isEmpty else { return nil }
            return SidebarRepoGroup(repo: repo, workspaces: Array(recent))
        }
    }

    // MARK: - Actions

    private func select(_ workspace: Workspace) {
        app.selection = .workspace(workspace.id)
    }

    /// Handed to `RootView`, which owns the only create sheet in the app.
    private func requestWorkspace(in repo: Repo?) {
        NotificationCenter.default.post(name: .batonNewWorkspace, object: repo)
    }

    private func addProject() {
        guard let path = ProjectFolderPicker.choose() else { return }
        Task { await app.addRepository(at: path) }
    }
}
