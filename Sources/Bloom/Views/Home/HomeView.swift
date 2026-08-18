import SwiftUI
import BloomCore

/// The centre pane when nothing is selected.
///
/// Home answers three questions in the order a developer running several agents actually asks them:
/// what has stopped and needs me, what is moving, and what is here. The shortlist at the top is the
/// first, the marks and totals on the blocks below are the second and third, and the grouping by
/// project is what keeps a screen of twenty workspaces readable, because a developer thinks in
/// projects before they think in branches.
///
/// Everything drawn here comes out of `HomeDigest`, which resolves each workspace through
/// `WorkspaceStatus` exactly once per pass. That is deliberate: the sidebar, this pane and the
/// legend all describe the same thirteen states, and the moment Home decides for itself what counts
/// as interesting, the two halves of the window start disagreeing about the same workspace.
struct HomeView: View {
    @Environment(AppModel.self) private var app

    @State private var hovered: String?

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
    }

    // MARK: - Populated

    private var content: some View {
        let digest = digest

        return ScrollView {
            VStack(alignment: .leading, spacing: Metrics.spacingSection) {
                HomeWelcomeHeader(
                    greeting: greeting,
                    summary: summary(digest),
                    counts: counts(digest),
                    onCreateWorkspace: { requestWorkspace(in: nil) }
                )

                if !digest.attention.isEmpty {
                    HomeAttentionSection(
                        workspaces: digest.attention,
                        hovered: $hovered,
                        onSelect: select
                    )
                }

                ForEach(digest.projects) { project in
                    HomeRepoSection(
                        project: project,
                        hovered: $hovered,
                        onCreateWorkspace: { requestWorkspace(in: $0) },
                        onSelect: select
                    )
                }

                if digest.workspaceCount < Self.settledIn {
                    HomeNextSteps(
                        repo: app.repos.first,
                        onCreateWorkspace: { requestWorkspace(in: nil) },
                        onAddProject: addProject
                    )
                }
            }
            .padding(Metrics.pane)
            .frame(maxWidth: Self.readableWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// Past this many workspaces the user has plainly worked out what a workspace is, and the
    /// getting-started block stops being help and starts being clutter.
    private static let settledIn = 3

    /// A ceiling on the content, so a full-screen window lays out three or four cards across
    /// instead of stretching one row of them to a metre wide.
    private static let readableWidth: CGFloat = 1_100

    // MARK: - Derived

    /// Worked out in `body` rather than cached in `@State`, because the verdict on a workspace
    /// depends on things `app.workspaces` does not carry: whether an agent has a turn open, and what
    /// GitHub last said about the branch. A cached digest keyed on the workspace list alone showed
    /// stale marks for exactly the workspaces the user cares about most. One grouped pass over the
    /// list is cheap; what was expensive, and what this replaced, was filtering and sorting the
    /// whole list once per project per redraw.
    private var digest: HomeDigest {
        HomeDigest.build(repos: app.repos, workspaces: app.workspaces) { workspace in
            // Read, never requested. The sidebar rows already keep this cache warm for every
            // workspace on screen, and a second poller would double the `gh` subprocesses for the
            // same answer. With the sidebar collapsed the lookup simply misses, and `resolve` falls
            // back to what git alone can say, which is what it is built to do.
            let pullRequest = WorkspacePullRequests.shared.pullRequest(for: workspace.id)
            let status = WorkspaceStatus.resolve(
                workspace: workspace,
                isRunning: app.isRunning(workspace),
                pullRequest: pullRequest
            )
            return HomeVerdict(status: status, summary: status.summary(pullRequest: pullRequest))
        }
    }

    private var greeting: String {
        let name = NSFullUserName().components(separatedBy: .whitespaces).first ?? ""
        return name.isEmpty ? "Welcome back" : "Welcome back, \(name)"
    }

    private func summary(_ digest: HomeDigest) -> String {
        guard digest.workspaceCount > 0 else {
            return "No workspaces yet. Start one and an agent gets to work."
        }
        let workspaces = digest.workspaceCount == 1
            ? "1 workspace"
            : "\(digest.workspaceCount) workspaces"
        let projects = digest.projectCount == 1 ? "1 project" : "\(digest.projectCount) projects"
        return "\(workspaces) across \(projects)"
    }

    /// Only the counts that are not zero. A strip reading "0 running, 0 waiting" is a report that
    /// nothing is happening dressed up as a dashboard.
    private func counts(_ digest: HomeDigest) -> [HomeCount] {
        var counts: [HomeCount] = []
        if digest.runningCount > 0 {
            counts.append(
                HomeCount(
                    text: "\(digest.runningCount) running",
                    systemImage: "bolt.fill",
                    tint: Palette.running
                )
            )
        }
        if digest.settingUpCount > 0 {
            counts.append(
                HomeCount(
                    text: "\(digest.settingUpCount) setting up",
                    systemImage: "gearshape",
                    tint: Palette.textSecondary
                )
            )
        }
        if digest.waitingCount > 0 {
            // The accent is what this app uses for "this is waiting for you" rather than for a
            // machine, which is exactly what this count is.
            counts.append(
                HomeCount(
                    text: "\(digest.waitingCount) need you",
                    systemImage: "exclamationmark.circle",
                    tint: Palette.accent
                )
            )
        }
        return counts
    }

    // MARK: - Empty

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Add your first project", systemImage: "folder.badge.plus")
        } description: {
            Text("Point Bloom at a git repository. Every workspace you start gets its own worktree and its own agent, so they never step on each other.")
        } actions: {
            Button("Choose a folder", systemImage: "folder", action: addProject)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Actions

    private func select(_ entry: HomeWorkspace) {
        app.selection = .workspace(entry.id)
    }

    /// Handed to `RootView`, which owns the only create sheet in the app.
    private func requestWorkspace(in repo: Repo?) {
        NotificationCenter.default.post(name: .bloomNewWorkspace, object: repo)
    }

    private func addProject() {
        guard let path = ProjectFolderPicker.choose() else { return }
        Task { await app.addRepository(at: path) }
    }
}
