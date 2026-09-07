import SwiftUI

/// The actual create-window control in both states, without a project or a running agent.
struct WorkspaceSetupOptionGallery: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            WorkspaceSetupOption(isEnabled: .constant(true))
            WorkspaceSetupOption(isEnabled: .constant(false))
        }
        .padding(Metrics.gutter)
        .frame(width: 760)
        .background(Palette.surface)
    }
}
