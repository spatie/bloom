import SwiftUI

/// The strip before there is a pull request: which branch you are on, and the button that pushes
/// it and opens one.
///
/// The branch name is the part that gives way. It is given a lower layout priority than the
/// button so a long branch truncates from the head, which keeps the readable end of it, rather
/// than pushing the only action in the strip off the edge of the pane. Below even that width the
/// button drops its title, the way a toolbar item does.
struct PullRequestCreator: View {
    var branch: String
    var baseBranch: String
    var isWorking: Bool
    var action: () -> Void

    /// Whether gh can be used at all. Held here rather than passed in because it is a fact about
    /// the machine, not about this branch, and it is asked once for the whole app.
    @State private var github: GitHubAvailability.State = .unknown

    var body: some View {
        HStack(spacing: InspectorLayout.gap) {
            Image(systemName: "arrow.triangle.branch")
                .font(Typo.caption)
                .imageScale(.medium)
                .foregroundStyle(Palette.textTertiary)
                .accessibilityHidden(true)

            Text(branch)
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.head)
                .layoutPriority(-1)
                .help(branch)
                .accessibilityLabel("Branch \(branch)")

            Spacer(minLength: Metrics.spacingSmall)

            if isWorking {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Working")
            } else if github == .unavailable {
                // A button that can only fail is worse than no button. The state is stated
                // plainly instead, with the one command that fixes it in the tooltip.
                Text("GitHub CLI unavailable")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                    .help("Install gh and run gh auth login to open pull requests from Baton.")
            } else {
                ViewThatFits(in: .horizontal) {
                    createButton.labelStyle(.titleOnly)
                    createButton.labelStyle(.iconOnly)
                }
                .fixedSize()
            }
        }
        // Optimistic while the probe runs: the button is shown until gh is known to be missing,
        // so the common case never flickers through a disabled state.
        .task { github = await GitHubAvailability.shared.isReady() ? .ready : .unavailable }
    }

    private var createButton: some View {
        Button("Create pull request", systemImage: "arrow.triangle.pull", action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Push this branch and open a pull request against \(baseBranch)")
    }
}
