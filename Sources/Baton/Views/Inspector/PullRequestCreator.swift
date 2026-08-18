import SwiftUI

/// The strip before there is a pull request: which branch you are on, and the button that pushes
/// it and opens one.
struct PullRequestCreator: View {
    var branch: String
    var baseBranch: String
    var isWorking: Bool
    var action: () -> Void

    var body: some View {
        HStack(spacing: InspectorLayout.gap) {
            Image(systemName: "arrow.triangle.pull")
                .font(Typo.caption)
                .imageScale(.medium)
                .foregroundStyle(Palette.textTertiary)
                .accessibilityHidden(true)

            Text(branch)
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.head)
                .accessibilityLabel("Branch \(branch)")

            Spacer(minLength: InspectorLayout.tight * 2)

            if isWorking {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Working")
            } else {
                Button("Create pull request", action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Push this branch and open a pull request against \(baseBranch)")
            }
        }
    }
}
