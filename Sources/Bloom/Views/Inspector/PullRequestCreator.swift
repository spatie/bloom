import SwiftUI
import BloomCore

/// The strip before there is a pull request: the branch and one button for its next action.
///
/// The button opens a compact choice beside the strip. Its counterpart once there is a pull
/// request is Merge, in the same place and at the same weight.
///
/// On a branch with nothing on it there is no button. See `body`.
///
/// The popover offers an agent turn or a direct commit, push and gh create sequence.
///
/// The branch name is the part that gives way. It is given a lower layout priority than the
/// button so a long branch truncates from the head, which keeps the readable end of it, rather
/// than pushing the only action in the strip off the edge of the pane. Below even that width the
/// button drops its title, the way a toolbar item does.
///
/// A rung below the state headline `PullRequestSummary` draws in the same band, on purpose. That
/// one is a state you are waiting on and it is the top of the column; this one is a branch name
/// the reader chose and already knows, so it is reading size rather than above it. At 15 points a
/// realistic branch name truncates from the head at the pane's default width and the strip turns
/// into a row about an ellipsis. Both strips carry the same detail rung underneath, so the two
/// states of the same band still share one rhythm.
struct PullRequestCreator: View {
    var model: WorkspaceModel
    var branch: String
    var baseBranch: String
    var isWorking: Bool
    /// Creating a pull request submits a message, so a busy agent can still accept the request.
    var branchActions: BranchActionAvailability
    /// Where a sign in would run, if the quiet line below the branch is pressed. Empty for a
    /// workspace with no worktree on this Mac, which is also one that is never in the dark.
    var worktree: String
    var github: GitHubAvailability.State
    var forge: Forge = .gitHub
    /// Whether this branch has anything on it at all. A worktree identical to its base has nothing
    /// to open a pull request for, and Bloom knows that for free, so it says so here rather than
    /// spending a whole agent turn on the agent finding out.
    ///
    /// It settles both halves of the strip: the line under the branch name, and whether there is a
    /// button at all.
    var hasChanges: Bool
    var hasReadChanges = true
    /// Set for the branch this workspace was carried on to when its pull request merged, and only
    /// while nothing has been committed to it. It is the difference between an empty branch that
    /// has just been cut from a landed pull request and an empty branch nobody has done anything
    /// on, which read identically until `ContinuedBranch` gave the first of them a sentence.
    var continued: ContinuedBranch?
    var action: (PullRequestCreationRoute) -> Void

    @State private var isShowingBranchActions = false

    var body: some View {
        HStack(spacing: InspectorLayout.gap) {
            Image(systemName: "arrow.triangle.branch")
                .font(Typo.title)
                .imageScale(.medium)
                .foregroundStyle(Palette.textTertiary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Metrics.spacingHair) {
                // Keep the readable end of a long branch. The context menu below makes the full
                // name copyable without a hover card covering the band.
                Text(branch)
                    .font(Typo.title)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .accessibilityLabel("Branch \(branch)")

                if github.isUsable {
                    Text(subtitle)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    // The one place the strip admits it cannot see GitHub, and the natural place
                    // to hang the fix off. Quiet, because the button beside it works regardless.
                    //
                    // Two words rather than a sentence, and pinned to the leading edge. The full
                    // "Connect GitHub to see pull requests" did not fit the inspector's default
                    // width, and `.link` centres its title in whatever frame it is given, so it
                    // wrapped to two centred lines under a left-aligned branch name. The reason
                    // is in the tooltip, where a sentence has room to be a sentence.
                    Button("Connect GitHub") {
                        GitHubSignIn.shared.present(directory: worktree)
                    }
                    .linkButton()
                    .font(Typo.caption)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(
                        github == .notInstalled
                            ? "The gh command is not installed, so Bloom cannot tell whether this branch has a pull request."
                            : "The GitHub CLI is signed out, so Bloom cannot tell whether this branch has a pull request."
                    )
                }
            }
            .layoutPriority(-1)

            Spacer(minLength: Metrics.spacingSmall)

            if isWorking {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Working")
            } else if hasChanges {
                // Nothing at all on a branch that is identical to its base, rather than a greyed
                // out button. There is no work here to open a pull request for and nothing in this
                // strip, this column or this window will make there be any: the next thing that
                // happens is the agent editing a file, which is not something a button can wait
                // for. A control that cannot be used and cannot be brought back to life from where
                // the reader is standing is not a control, it is a picture of one, and the line
                // under the branch name already says what the state is.
                //
                // It comes back on the same fact it used to be enabled by, `hasChanges`, which is
                // the inspector's own file list with the workspace's stored diff counts behind it.
                // Nothing extra is polled for it and nothing is later than it was: the list is
                // re-read when a turn ends and every six seconds while Bloom is frontmost, which
                // is what used to take the button from grey to live.
                // The `.fixedSize()` is on the candidates rather than over the row. Outside, it
                // proposed an unspecified width, a `ViewThatFits` reads that as room for its
                // first candidate, and "Create pull request" therefore kept its title at every
                // pane width and the icon-only form was unreachable. See
                // `PullRequestSummary.continueButton`.
                branchActionsButton.fixedSize()
            }
        }
        // Reading the name is half of what a truncated branch name is wanted for. The other half
        // is pasting it into a terminal, and a tooltip cannot be copied.
        //
        // Here as well as in the inspector toolbar's menu, and that is not a duplicate path for
        // its own sake: the toolbar's copy is behind an ellipsis in a different bar, which is a
        // place to go looking rather than a place to arrive, and a reader who wants this branch's
        // name has their pointer on this branch's name. `PullRequestSummary` puts its own copy
        // and share items on the strip for the same reason.
        .contextMenu {
            Button("Copy Branch Name") { Clipboard.copy(branch) }
        }
        // Optimistic while the probe runs, and silent about the answer either way. Learning that
        // gh is signed out is worth one quiet line here; it is never worth a dialog nobody asked
        // for.
        .task { await GitHubAvailability.shared.check() }
    }

    /// What the branch is for, in the one line under it: where it is headed, or why the button is
    /// not going to do anything yet.
    private var subtitle: String {
        // The held back band says so on the line it already has, for the reason
        // `PullRequestSummary.detailLine` gives: a disabled button that explains itself only on
        // hover is a button most people never get an explanation from.
        if let note = branchActions.note { return note }
        if !hasChanges, !hasReadChanges { return "Comparing with \(baseBranch)…" }
        guard hasChanges else { return ContinuedBranch.line(on: branch, continued: continued) }
        return "No \(forge.request) yet. Target \(baseBranch)."
    }

    /// A single title-bar control. Its popover chooses how to create the PR now.
    private var branchActionsButton: some View {
        Button("Create \(forge.shortRequest)") { isShowingBranchActions = true }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: Metrics.corner))
            .tint(Palette.controlAccent)
            .controlSize(.regular)
            .disabled(!branchActions.isAllowed)
            .help("Create a \(forge.request) for \(branch)")
            .popover(isPresented: $isShowingBranchActions, arrowEdge: .top) {
                BranchActionsPopover(model: model, onCreatePullRequest: action)
            }
    }
}
