import SwiftUI

/// The shortlist at the top of Home: the workspaces that have stopped and cannot move again until
/// somebody does something about them.
///
/// The whole point of running agents in parallel is that most of them are somebody else's problem
/// most of the time. What the user actually opens this window for is the handful that are not: a
/// setup script that fell over, a turn nobody has read, a branch CI has rejected, a pull request
/// that landed. Those are spread across every project block below, and finding them meant reading
/// all of them.
///
/// Which states count is `WorkspaceStatus.homeLane`, and the order is `WorkspaceStatus`'s own
/// precedence chain, so this lane cannot come to a different conclusion from the mark on the card
/// or from the sidebar row for the same workspace.
struct HomeAttentionSection: View {
    var workspaces: [HomeWorkspace]
    @Binding var hovered: String?
    var onSelect: (HomeWorkspace) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.inset) {
            HStack(spacing: Metrics.spacing) {
                Text("Needs you")
                    .font(Typo.title)
                    .foregroundStyle(Palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                Text(subtitle)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)

                Spacer(minLength: Metrics.spacingWide)
            }

            HomeCardGrid(workspaces: workspaces, hovered: $hovered, onSelect: onSelect)
        }
    }

    private var subtitle: String {
        workspaces.count == 1
            ? "One workspace is waiting on you"
            : "\(workspaces.count) workspaces are waiting on you"
    }
}
