import SwiftUI
import BloomCore

/// What the pull request strip says over the project's own checkout, which has no pull requests.
///
/// The same branch line `PullRequestCreator` draws, so the band reads the same from one workspace
/// to the next, without its button: Create pull request would open one from the owner's own
/// checkout, usually from the default branch into itself. See `WorkspaceKind.hasPullRequests`.
struct ProjectCheckoutBand: View {
    let branch: String

    var body: some View {
        HStack(spacing: InspectorLayout.gap) {
            Image(systemName: "folder")
                .font(Typo.title)
                .imageScale(.medium)
                .foregroundStyle(Palette.textTertiary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Metrics.spacingHair) {
                Text(branch)
                    .font(Typo.title)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .accessibilityLabel("Branch \(branch)")

                Text("The project's own checkout")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
        .contextMenu {
            Button("Copy Branch Name") { Clipboard.copy(branch) }
        }
    }
}
