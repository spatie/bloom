import SwiftUI
import BloomCore

/// The pull request strip above the inspector tabs.
///
/// The bar owns the state colour rather than its contents doing, so the tint runs the full width
/// of the pane including the insets its rows keep. A wash painted by the row inside had to grow
/// itself back out with a negative margin, which is a number that has to be kept in step with the
/// inset by hand.
///
/// It polls while it is on screen and stops when the inspector is hidden, because the state it
/// shows changes on GitHub's schedule rather than the user's. The poll is silent: a machine
/// without `gh`, or with `gh` signed out, simply never gets a pull request back, and a background
/// refresh is never a reason to put a dialog in front of anybody.
struct PullRequestBar: View {
    let model: WorkspaceModel

    /// How often GitHub is asked again while the bar is on screen.
    private static let pollInterval = Duration.seconds(20)

    @State private var isWorking = false
    @State private var report: MergeReport?

    /// What is left to say after a button was pressed. Not an alert: see `InspectorNotice`.
    private struct MergeReport: Identifiable {
        let id = UUID()
        let tone: InspectorNotice.Tone
        let title: String
        let message: String
        var details: String?
    }

    var body: some View {
        VStack(spacing: 0) {
            strip
            if let report {
                Hairline()
                InspectorNotice(
                    tone: report.tone,
                    title: report.title,
                    message: report.message,
                    details: report.details,
                    onDismiss: { self.report = nil }
                )
            }
        }
        .task(id: model.workspace.id) { await poll() }
    }

    private var strip: some View {
        content
            .padding(.horizontal, InspectorLayout.inset)
            .frame(height: InspectorLayout.pullRequestBarHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                // A tint over the surface rather than instead of it, so the strip keeps the
                // pane's own colour underneath and the state only ever adds to it.
                ZStack {
                    Palette.surface
                    if let tint {
                        tint.opacity(washOpacity)
                    }
                }
            }
    }

    /// Nil until there is a pull request, and for the states that have nothing to signal.
    ///
    /// The same status the strip's contents draw, local work weighed in, so a branch holding work
    /// GitHub has not got turns the whole band amber rather than only its headline.
    private var tint: Color? {
        model.pullRequest?.status(local: model.localWork).tone.color
    }

    /// How hard the band carries its colour.
    ///
    /// An open pull request is asking for something and gets the full wash. Merged and closed are
    /// answers: they keep the hue, so "did this land" is still one glance, and they give it up as
    /// volume, because the reading matter in this column is the diff below and a finished branch
    /// has no business competing with it. `PullRequestSummary` makes the same split in type.
    private var washOpacity: Double {
        model.pullRequest?.isOpen == false
            ? InspectorLayout.bandOpacityQuiet
            : InspectorLayout.bandOpacity
    }

    @ViewBuilder
    private var content: some View {
        if let pullRequest = model.pullRequest {
            PullRequestSummary(
                pullRequest: pullRequest,
                baseBranch: model.workspace.baseBranch,
                worktree: model.workspace.path,
                localWork: model.localWork,
                isWorking: isWorking,
                onMerge: merge,
                onPush: push
            )
        } else {
            PullRequestCreator(
                branch: model.workspace.branch,
                baseBranch: model.workspace.baseBranch,
                isWorking: isWorking || model.isLoadingPullRequest,
                isAgentBusy: model.isRunning,
                worktree: model.workspace.path,
                hasChanges: hasChanges,
                action: createPullRequest
            )
        }
    }

    /// Whether the branch has anything on it. The inspector's own list first, because it is the
    /// freshest thing here, and the workspace row's counts behind it for the moment before the
    /// list has been read.
    private var hasChanges: Bool {
        !model.changedFiles.isEmpty || model.workspace.hasDiff
    }

    // MARK: - Actions

    private func poll() async {
        while !Task.isCancelled {
            await model.refreshPullRequest()
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    /// Creation is the agent's job: it pushes, writes the description and calls `gh` with the
    /// project's own conventions in context. Bloom only composes the turn. Reading the pull
    /// request's status afterwards, and merging it, still go through `gh` from here, because those
    /// are questions with one right answer rather than work that needs judgement.
    private func createPullRequest() {
        isWorking = true
        report = nil

        Task {
            defer { isWorking = false }
            if let refusal = await model.requestPullRequest() {
                report = MergeReport(
                    tone: .info, title: "Nothing was sent", message: refusal
                )
            }
        }
    }

    /// Hands the outstanding work to the agent, the same way Create pull request does.
    ///
    /// Nothing here runs git. Bloom does not write commit messages, so the whole of this is
    /// composing a turn and sending it; what comes back is a normal turn in the transcript, and
    /// the strip notices the result on its next refresh like any other change to the worktree.
    private func push() {
        isWorking = true
        report = nil

        Task {
            defer { isWorking = false }
            if let refusal = await model.requestPush() {
                report = MergeReport(
                    tone: .info, title: "Nothing was sent", message: refusal
                )
            }
        }
    }

    /// Merging is two things happening in order, and they are reported separately.
    ///
    /// The pull request lands over the network, and only then is there any tidying up. A merge
    /// that worked is never announced as a failure, and a leftover is described as a leftover.
    private func merge(_ method: GitHub.MergeMethod) {
        guard let pullRequest = model.pullRequest else { return }
        isWorking = true
        report = nil
        let worktree = model.workspace.path

        Task {
            defer { isWorking = false }
            do {
                let outcome = try await GitHubBridge.merge(
                    pullRequest, worktree: worktree, method: method
                )
                // The durable record of it goes in the transcript, which is where "what happened
                // to this workspace" lives now. The strip says the rest by turning purple and
                // saying Merged a second later.
                model.record(.merged(pullRequest: pullRequest.number, outcome: outcome))
            } catch {
                let reason = GitHub.mergeFailureSentence(error)
                model.record(.mergeFailed(pullRequest: pullRequest.number, reason: reason))
                // And here as well, because this one means the button the user just pressed did
                // nothing, and they are looking at the button. The command that failed is behind
                // the disclosure rather than in the sentence.
                report = MergeReport(
                    tone: .failure,
                    title: "#\(pullRequest.number) was not merged",
                    message: reason + " Nothing on this machine was changed.",
                    details: "\(error)"
                )
            }
            await model.refreshPullRequest()
        }
    }
}
