import SwiftUI
import BatonCore

/// The pull request strip above the inspector tabs: what number it is, how CI feels about it,
/// and the one button that finishes the job.
///
/// It polls while it is on screen and stops when the inspector is hidden, because the state it
/// shows changes on GitHub's schedule rather than the user's.
struct PullRequestBar: View {
    let model: WorkspaceModel

    @State private var pendingMerge: GitHub.MergeMethod?
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        HStack(spacing: 8) {
            if let pullRequest = model.pullRequest {
                existing(pullRequest)
            } else {
                creator
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface)
        .task(id: model.workspace.id) {
            while !Task.isCancelled {
                await model.refreshPullRequest()
                try? await Task.sleep(for: .seconds(20))
            }
        }
        .confirmationDialog(
            "Merge pull request #\(model.pullRequest?.number ?? 0)?",
            isPresented: Binding(
                get: { pendingMerge != nil },
                set: { if !$0 { pendingMerge = nil } }
            ),
            presenting: pendingMerge
        ) { method in
            Button(Self.label(for: method), role: .destructive) { merge(method) }
            Button("Cancel", role: .cancel) {}
        } message: { method in
            Text("\(Self.label(for: method)) into \(model.workspace.baseBranch) and delete the branch.")
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - With a pull request

    @ViewBuilder
    private func existing(_ pullRequest: PullRequest) -> some View {
        Button {
            GitHubBridge.open(pullRequest.url)
        } label: {
            Chip(
                text: "#\(pullRequest.number)",
                systemImage: "arrow.triangle.pull",
                tint: Palette.accent,
                background: Palette.accent.opacity(0.12)
            )
        }
        .buttonStyle(.plain)
        .help(pullRequest.title)

        if pullRequest.isDraft {
            Chip(text: "Draft")
        }

        Text(statusText(pullRequest))
            .font(Typo.caption)
            .foregroundStyle(statusColor(pullRequest))
            .lineLimit(1)
            .truncationMode(.tail)

        Spacer(minLength: 4)

        if isWorking {
            ProgressView().controlSize(.small)
        } else if pullRequest.state.uppercased() == "OPEN" {
            mergeButton
        } else {
            Chip(text: pullRequest.state.capitalized)
        }
    }

    private var mergeButton: some View {
        Menu {
            Button("Merge commit") { pendingMerge = .merge }
            Button("Squash and merge") { pendingMerge = .squash }
            Button("Rebase and merge") { pendingMerge = .rebase }
        } label: {
            Text("Merge")
                .font(Typo.captionEmphasis)
        } primaryAction: {
            pendingMerge = .squash
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Palette.positive, in: RoundedRectangle(cornerRadius: Metrics.cornerSmall))
        .foregroundStyle(Palette.textInverted)
    }

    private func statusText(_ pullRequest: PullRequest) -> String {
        if !pullRequest.checksSummary.isEmpty { return pullRequest.checksSummary }
        if let decision = pullRequest.reviewDecision, !decision.isEmpty {
            return decision.replacingOccurrences(of: "_", with: " ").capitalized
        }
        return pullRequest.title
    }

    private func statusColor(_ pullRequest: PullRequest) -> Color {
        switch pullRequest.checks {
        case .passing: Palette.positive
        case .failing: Palette.negative
        case .pending: Palette.warning
        case .none: Palette.textSecondary
        }
    }

    // MARK: - Without one

    @ViewBuilder
    private var creator: some View {
        Image(systemName: "arrow.triangle.pull")
            .font(.system(size: 10))
            .foregroundStyle(Palette.textTertiary)

        Text(model.workspace.branch)
            .font(Typo.caption)
            .foregroundStyle(Palette.textSecondary)
            .lineLimit(1)
            .truncationMode(.head)

        Spacer(minLength: 4)

        if isWorking || model.isLoadingPullRequest {
            ProgressView().controlSize(.small)
        } else {
            Button("Create pull request") { createPullRequest() }
                .font(Typo.captionEmphasis)
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Palette.accent, in: RoundedRectangle(cornerRadius: Metrics.cornerSmall))
                .foregroundStyle(Palette.textInverted)
        }
    }

    // MARK: - Actions

    /// Pushing first is not optional: gh refuses to open a pull request for a branch the remote
    /// has never heard of, and the agent's work only ever exists locally until now.
    private func createPullRequest() {
        isWorking = true
        let workspace = model.workspace

        Task {
            defer { isWorking = false }
            do {
                try await GitHubBridge.push(worktree: workspace.path, branch: workspace.branch)
                let created = try await GitHubBridge.createPullRequest(
                    worktree: workspace.path,
                    base: workspace.baseBranch,
                    title: workspace.name,
                    body: "",
                    draft: false
                )
                model.pullRequest = created
            } catch {
                errorMessage = "\(error)"
            }
            await model.refreshPullRequest()
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

    private static func label(for method: GitHub.MergeMethod) -> String {
        switch method {
        case .merge: "Merge commit"
        case .squash: "Squash and merge"
        case .rebase: "Rebase and merge"
        }
    }
}
