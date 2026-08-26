import SwiftUI
import BloomCore

/// The pull request strip along the top edge of the window, over the inspector column.
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
///
/// It is exactly one row tall, always, and that is a hard requirement rather than a preference.
/// The strip is a title bar accessory now (`TitleBarStrip`), and an accessory is laid out from a
/// frame its controller sets by hand rather than from anything SwiftUI measures. Anything this
/// view draws below that one row is drawn into a band with no room for it: the content is centred
/// in the frame and cut off at both ends, which is what happened to the Continue notice. So what
/// the strip has to SAY, as opposed to show, goes to `model.pullRequestNotice` and is drawn by
/// `InspectorView` at the top of the column, one row lower and as tall as it needs to be.
struct PullRequestBar: View {
    let model: WorkspaceModel

    /// Continue and Archive are both about the workspace rather than about the pull request, so
    /// they go through the app the way every other archive does rather than being reimplemented
    /// against git from a view.
    @Environment(AppModel.self) private var app

    /// How often GitHub is asked again while the bar is on screen.
    private static let pollInterval = Duration.seconds(20)

    @State private var isWorking = false

    /// Where an answer goes. Set here, drawn in the column: see the note on the type.
    private var report: PullRequestNotice? {
        get { model.pullRequestNotice }
        nonmutating set { model.pullRequestNotice = newValue }
    }

    var body: some View {
        strip
            .task(id: model.workspace.id) { await poll() }
            // The other half of the button. `WorkspaceModel` counts the turns that Create pull
            // request started and that ended with no pull request; this is where one gets said
            // out loud.
            .onChange(of: model.pullRequestShortfalls) { _, _ in reportShortfall() }
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
                isAgentBusy: model.isRunning,
                onMerge: merge,
                onPush: push,
                onFixConflicts: { fixConflicts(on: pullRequest) },
                onContinue: { carryOn(after: pullRequest) },
                onArchive: archive
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
        // The first pass is an arrival rather than a poll, and it is allowed a recent answer.
        // This runs on `.task(id:)`, so it used to send two gh calls to GitHub every time the
        // window landed on a workspace, including landing back on one it had left four seconds
        // earlier. Every pass after this one asks GitHub properly: twenty seconds is exactly long
        // enough that an answer from the last one is not worth having.
        var maxAge = WorkspaceModel.pullRequestArrivalMaxAge
        while !Task.isCancelled {
            await model.refreshPullRequest(maxAge: maxAge)
            maxAge = .zero
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    /// Creation is the agent's job: it pushes, writes the description and calls `gh` with the
    /// project's own conventions in context. Bloom only composes the turn. Reading the pull
    /// request's status is the one thing left that still goes through `gh` from here, because it
    /// is a question with one right answer rather than work that needs judgement.
    private func createPullRequest() {
        isWorking = true
        report = nil

        Task {
            defer { isWorking = false }
            if let refusal = await model.requestPullRequest() {
                report = PullRequestNotice(
                    tone: .info, title: "Nothing was sent", message: refusal
                )
            }
        }
    }

    /// What to say when the agent finished the turn and there is still no pull request.
    ///
    /// Quiet about it when Bloom cannot see GitHub at all, because then it has not found out that
    /// there is no pull request: it has only found out that it cannot ask. `PullRequestCreator`
    /// already says that, in the one line under the branch name.
    ///
    /// A leftover rather than a failure. The agent ran, the worktree may well have been pushed,
    /// and what is missing is the last step, so the sentence points at the transcript rather than
    /// claiming to know what stopped it.
    private func reportShortfall() {
        guard GitHubAvailability.shared.state.isUsable else { return }
        report = PullRequestNotice(
            tone: .leftover,
            title: "No pull request was opened",
            message: "\(model.workspace.name) finished the turn without one. The end of the "
                + "transcript says what stopped it: a rejected push, or a command the permission "
                + "mode would not let it run, are the two usual answers.",
            details: nil
        )
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
                report = PullRequestNotice(
                    tone: .info, title: "Nothing was sent", message: refusal
                )
            }
        }
    }

    /// Hands the conflict to the agent, the same way the other three buttons hand it their work.
    ///
    /// Nothing here runs git, and there is nothing to report on success either: what comes back is
    /// an ordinary turn in the transcript, and the strip notices the resolved worktree on its next
    /// refresh like any other change on this disk.
    ///
    /// The turn pushes the resolution itself unless it is unsure of it, so the pull request stops
    /// being conflicted on GitHub without anybody pressing anything else. It used to stop at the
    /// commit and leave Commit and push to the reader, which read as finished and was not: see the
    /// argument on `PromptRegistry.fixConflicts`. Commit and push is still the button the strip
    /// offers when an agent stopped short.
    private func fixConflicts(on pullRequest: PullRequest) {
        isWorking = true
        report = nil

        Task {
            defer { isWorking = false }
            if let refusal = await model.requestFixConflicts(pullRequest) {
                report = PullRequestNotice(
                    tone: .info, title: "Nothing was sent", message: refusal
                )
            }
        }
    }

    /// Cuts a fresh branch in this worktree and hands the session on to it.
    ///
    /// Reported here rather than silently, in all three directions. A refusal names the condition
    /// that stopped it, because Continue is the sort of button that looks broken when nothing
    /// happens. A success says which branch and which base, because those are the two facts the
    /// reader now has to hold, and it repeats the warning when the base could not be fetched: a
    /// branch cut from a stale copy of main is a thing you want to know before you build on it.
    private func carryOn(after pullRequest: PullRequest) {
        isWorking = true
        report = nil

        Task {
            defer { isWorking = false }
            switch await app.continueAfterMerge(model.workspace, pullRequest: pullRequest) {
            case .continued(let continuation):
                report = PullRequestNotice(
                    tone: continuation.base == .fetched ? .info : .leftover,
                    title: "Continuing on \(continuation.branch)",
                    message: continuation.sentence,
                    details: continuation.base.warning
                )
            case .refused(let refusal):
                report = PullRequestNotice(
                    tone: .info, title: "Nothing was changed", message: refusal.sentence
                )
            case .failed(let reason):
                report = PullRequestNotice(
                    tone: .failure,
                    title: "Could not continue",
                    // The reassurance used to be appended here, which read as a contradiction
                    // over a worktree that had been deleted. `WorkspaceTrouble` carries it in
                    // the one sentence where it is true.
                    message: reason,
                    details: nil
                )
            }
        }
    }

    /// Archives, through the app's own path with every safety check intact.
    ///
    /// No confirmation is raised here. `AppModel.archive` decides for itself whether to ask, and
    /// on a merged pull request it will not unless there is genuinely something to lose. Why this
    /// button is allowed to be quiet while the sidebar's hover button never is, is written out at
    /// `PullRequestSummary.archiveButton`.
    private func archive() {
        Task { await app.archive(model.workspace) }
    }

    /// Hands the merge to the agent, the same way Create pull request and Commit and push do.
    ///
    /// Nothing here runs `gh`, and that is the change this whole file was rewritten for. Bloom used
    /// to merge over the network from this function and report the outcome into a notice, which
    /// left it with one thing to say about the case that happens most: GitHub refused, and the
    /// person needed a conversation rather than a red box. Now the request goes down the composer's
    /// own path, the commands run in the transcript under the permission mode the person set, and
    /// the strip notices the merge on its next refresh like any other change on GitHub.
    ///
    /// So there is nothing to report here on success. What used to be a `WorkspaceEvent` row is
    /// now the turn itself, a few points to the left, said in the agent's own words.
    private func merge(_ method: GitHub.MergeMethod) {
        guard let pullRequest = model.pullRequest else { return }
        isWorking = true
        report = nil

        Task {
            defer { isWorking = false }
            if let refusal = await model.requestMerge(pullRequest, method: method) {
                report = PullRequestNotice(
                    tone: .info, title: "Nothing was sent", message: refusal
                )
            }
        }
    }
}
