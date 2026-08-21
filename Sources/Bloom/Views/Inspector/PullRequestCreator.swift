import SwiftUI
import BloomCore

/// The strip before there is a pull request: which branch you are on, and the button that asks the
/// agent to open one.
///
/// The button is prominent and it is the only prominent thing in the column, because on a branch
/// with no pull request it is the whole point of the strip. Its counterpart once there is one is
/// Merge, in the same place, at the same weight.
///
/// On a branch with nothing on it there is no button. See `body`.
///
/// Nothing here is gated on the GitHub CLI. Pressing it composes a turn and sends it to this
/// workspace's own agent, which is already authenticated and already standing in the worktree, so
/// whether Bloom itself can talk to GitHub has no bearing on it. See `WorkspaceModel`.
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
    var branch: String
    var baseBranch: String
    var isWorking: Bool
    /// The workspace's agent is mid turn. The request is a turn of its own, so it has to wait
    /// rather than interleave with whatever was asked a moment ago.
    var isAgentBusy: Bool
    /// Where a sign in would run, if the quiet line below the branch is pressed.
    var worktree: String
    /// Whether this branch has anything on it at all. A worktree identical to its base has nothing
    /// to open a pull request for, and Bloom knows that for free, so it says so here rather than
    /// spending a whole agent turn on the agent finding out.
    ///
    /// It settles both halves of the strip: the line under the branch name, and whether there is a
    /// button at all.
    var hasChanges: Bool
    var action: () -> Void

    /// Whether the pointer is on the branch name, which is the only time anything asks whether it
    /// fits. See `TruncationProbe`: the answer costs a second text layout, so it is not one this
    /// strip pays for at rest.
    @State private var isHoveringBranch = false
    /// Whether the name is actually being cut off. False until the probe above says otherwise, so
    /// a branch that fits never grows a tooltip repeating what is already on screen.
    @State private var isBranchTruncated = false

    /// Whether Bloom itself can talk to GitHub. It has no bearing on the button, which goes to the
    /// agent, and every bearing on whether this strip can be trusted when it says there is no pull
    /// request: signed out, Bloom simply never found out.
    ///
    /// Read straight off the shared observable rather than copied into state, so signing in
    /// through the sheet takes the line below away at once instead of at the next redraw that
    /// happens to rebuild this view.
    private var github: GitHubAvailability.State { GitHubAvailability.shared.state }

    var body: some View {
        HStack(spacing: InspectorLayout.gap) {
            Image(systemName: "arrow.triangle.branch")
                .font(Typo.title)
                .imageScale(.medium)
                .foregroundStyle(Palette.textTertiary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                // Head truncation, and it stays: a branch is `murze/add-personal-notifications`
                // and the half that says which branch it is is the last half. What head
                // truncation costs is that the name is then unreachable, and that is what the two
                // modifiers under it buy back.
                Text(branch)
                    .font(Typo.title)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .reportsTruncation(
                        of: branch,
                        font: Typo.title,
                        isActive: isHoveringBranch,
                        into: $isBranchTruncated
                    )
                    .onHover { isHoveringBranch = $0 }
                    // Only when it is cut off. It used to be `.help(branch)` unconditionally,
                    // which is a tooltip that spends a second and a half of the reader's time
                    // repeating a string they can already see, and a tooltip that is usually
                    // noise is a tooltip nobody waits for. Now it appears exactly when it is the
                    // only way to read the name.
                    .help(isBranchTruncated ? branch : "")
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
                ViewThatFits(in: .horizontal) {
                    createButton.labelStyle(.titleOnly)
                    createButton.labelStyle(.iconOnly)
                }
                .fixedSize()
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
        hasChanges ? "No pull request yet. Target \(baseBranch)." : "Nothing has changed on this branch yet."
    }

    /// Tinted explicitly. An untinted `.borderedProminent` follows the system accent on this
    /// platform, and this is the button the strip exists for. See `PullRequestSummary.mergeButton`
    /// for the measurement, and for the one case no tint survives.
    private var createButton: some View {
        Button("Create pull request", systemImage: "arrow.triangle.pull", action: action)
            .buttonStyle(.borderedProminent)
            .tint(Palette.accentFill)
            .controlSize(.regular)
            // Only for a turn that is already running, which ends on its own. A branch with
            // nothing on it does not draw this button at all: see `body`.
            .disabled(isAgentBusy)
            .help(helpText)
    }

    private var helpText: String {
        if isAgentBusy {
            return "The agent is working. The request is sent as a turn, so it has to wait for this one."
        }
        // No path named. There are two, the project's own and Bloom's copy of the default, and
        // which one is in play is not something a tooltip should be teaching anybody.
        return "Ask this workspace's agent to push the branch and open a pull request against "
            + "\(baseBranch), following this project's pull request instructions."
    }
}
