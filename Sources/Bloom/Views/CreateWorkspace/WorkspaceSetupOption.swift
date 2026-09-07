import SwiftUI

/// A per-workspace choice, kept outside the composer controls that configure the agent.
struct WorkspaceSetupOption: View {
    @Binding var isEnabled: Bool

    var body: some View {
        Toggle(isOn: $isEnabled) {
            VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                Text("Run setup script")
                    .font(Typo.bodyEmphasis)
                    .foregroundStyle(Palette.textPrimary)
                Text("Use this project's setup script to prepare the new workspace.")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
        .tint(Palette.controlAccent)
        .accessibilityHint("Turn off to skip setup for this workspace only.")
        .padding(Metrics.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.corner))
    }
}
