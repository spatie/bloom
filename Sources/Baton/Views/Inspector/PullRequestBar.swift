import SwiftUI
import BatonCore

/// The pull request strip above the inspector tabs.
///
/// It polls while it is on screen and stops when the inspector is hidden, because the state it
/// shows changes on GitHub's schedule rather than the user's.
struct PullRequestBar: View {
    let model: WorkspaceModel

    /// How often GitHub is asked again while the bar is on screen.
    private static let pollInterval = Duration.seconds(20)

    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        content
            .padding(.horizontal, InspectorLayout.inset)
            .frame(height: InspectorLayout.barHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface)
            .task(id: model.workspace.id) { await poll() }
            .alert("Something went wrong", isPresented: $errorMessage.isPresent()) {
                // A lone OK that only dismisses is the system default.
            } message: {
                Text(errorMessage ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        if let pullRequest = model.pullRequest {
            PullRequestSummary(
                pullRequest: pullRequest,
                baseBranch: model.workspace.baseBranch,
                isWorking: isWorking,
                onMerge: merge
            )
        } else {
            PullRequestCreator(
                branch: model.workspace.branch,
                baseBranch: model.workspace.baseBranch,
                isWorking: isWorking || model.isLoadingPullRequest,
                isAgentBusy: model.isRunning,
                action: createPullRequest
            )
        }
    }

    // MARK: - Actions

    private func poll() async {
        while !Task.isCancelled {
            await model.refreshPullRequest()
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    /// Creation is the agent's job now: it pushes, writes the description and calls `gh` with the
    /// project's own conventions in context. Baton only composes the request. Reading the pull
    /// request's status afterwards, and merging it, still go through `gh` from here, because those
    /// are questions with one right answer rather than work that needs judgement.
    private func createPullRequest() {
        isWorking = true

        Task {
            defer { isWorking = false }
            errorMessage = await model.requestPullRequest()
        }
    }

    private func merge(_ method: GitHub.MergeMethod) {
        guard let pullRequest = model.pullRequest else { return }
        isWorking = true
        let worktree = model.workspace.path

        Task {
            defer { isWorking = false }
            do {
                try await GitHubBridge.merge(pullRequest, worktree: worktree, method: method)
            } catch {
                errorMessage = "\(error)"
            }
            await model.refreshPullRequest()
        }
    }
}
