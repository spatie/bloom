import SwiftUI
import BloomCore

/// The strip before there is a pull request: which branch you are on, and the button that asks the
/// agent to open one.
///
/// The button is prominent and it is the only prominent thing in the column, because on a branch
/// with no pull request it is the whole point of the strip. Its counterpart once there is one is
/// Merge, in the same place, at the same weight.
///
/// Nothing here is gated on the GitHub CLI. Pressing it composes a turn and sends it to this
/// workspace's own agent, which is already authenticated and already standing in the worktree, so
/// whether Bloom itself can talk to GitHub has no bearing on it. See `WorkspaceModel`.
///
/// The branch name is the part that gives way. It is given a lower layout priority than the
/// button so a long branch truncates from the head, which keeps the readable end of it, rather
/// than pushing the only action in the strip off the edge of the pane. Below even that width the
/// button drops its title, the way a toolbar item does.
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
    var hasChanges: Bool
    var action: () -> Void

    /// Whether Bloom itself can talk to GitHub. It has no bearing on the button, which goes to the
    /// agent, and every bearing on whether this strip can be trusted when it says there is no pull
    /// request: signed out, Bloom simply never found out.
    @State private var github: GitHubAvailability.State = .unknown

    var body: some View {
        HStack(spacing: InspectorLayout.gap) {
            Image(systemName: "arrow.triangle.branch")
                .font(Typo.caption)
                .imageScale(.medium)
                .foregroundStyle(Palette.textTertiary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(branch)
                    .font(Typo.captionEmphasis)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(branch)
                    .accessibilityLabel("Branch \(branch)")

                if github.isUsable {
                    Text(subtitle)
                        .font(Typo.micro)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    // The one place the strip admits it cannot see GitHub, and the natural place
                    // to hang the fix off. Quiet, because the button beside it works regardless.
                    Button("Connect GitHub to see pull requests") {
                        GitHubSignIn.shared.present(directory: worktree)
                    }
                    .buttonStyle(.link)
                    .font(Typo.micro)
                    .lineLimit(1)
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
            } else {
                ViewThatFits(in: .horizontal) {
                    createButton.labelStyle(.titleOnly)
                    createButton.labelStyle(.iconOnly)
                }
                .fixedSize()
            }
        }
        // Optimistic while the probe runs, and silent about the answer either way. Learning that
        // gh is signed out is worth one quiet line here; it is never worth a dialog nobody asked
        // for.
        .task { github = await GitHubAvailability.shared.check() }
    }

    /// What the branch is for, in the one line under it: where it is headed, or why the button is
    /// not going to do anything yet.
    private var subtitle: String {
        hasChanges ? "No pull request yet. Target \(baseBranch)." : "Nothing has changed on this branch yet."
    }

    /// Tinted explicitly. An untinted `.borderedProminent` follows the system accent on this
    /// platform and renders as grey glass on macOS 26, and this is the button the strip exists for.
    private var createButton: some View {
        Button("Create pull request", systemImage: "arrow.triangle.pull", action: action)
            .buttonStyle(.borderedProminent)
            .tint(Palette.accentFill)
            .controlSize(.regular)
            .disabled(isAgentBusy || !hasChanges)
            .help(helpText)
    }

    private var helpText: String {
        if !hasChanges {
            return "This worktree is identical to \(baseBranch). There is nothing to open a pull request for yet."
        }
        if isAgentBusy {
            return "The agent is working. The request is sent as a turn, so it has to wait for this one."
        }
        return "Ask this workspace's agent to push the branch and open a pull request against "
            + "\(baseBranch), following the instructions in \(PullRequestInstructions.path)."
    }
}
