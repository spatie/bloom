import SwiftUI
import BatonCore

/// What the toolbar says you are looking at: the project, the workspace and the branch you are
/// about to push.
///
/// Those are the three facts people keep needing, and the toolbar is where a Mac app puts them.
/// It is always present, even on Home, because an empty principal item collapses the flexible
/// space that pins the trailing toggles to the right of the toolbar, and controls that move as you
/// navigate are worse than a redundant word.
struct WindowTitleLabel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let workspace = app.selectedWorkspace {
            HStack(spacing: Metrics.spacing) {
                if let repo = app.repo(for: workspace) {
                    // The same mark, at the same size, as the one in front of the project in the
                    // sidebar and in a search result. It was a circle here and a rounded square
                    // there, which read as two different things.
                    RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                        .fill(Color(hexString: repo.accent))
                        .frame(width: Metrics.swatch, height: Metrics.swatch)
                        .accessibilityHidden(true)
                    Text(repo.name)
                        .font(Typo.label)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(Typo.micro)
                        .foregroundStyle(Palette.textTertiary)
                        .accessibilityHidden(true)
                }

                Text(workspace.name)
                    .font(Typo.labelEmphasis)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)

                Chip(
                    text: workspace.branch,
                    systemImage: "arrow.triangle.branch",
                    monospaced: true
                )
                .help(workspace.branch)
                .accessibilityLabel("Branch \(workspace.branch)")
            }
            .fixedSize()
        } else {
            Text(app.selection == .search ? "Search" : "Home")
                .font(Typo.labelEmphasis)
                .foregroundStyle(Palette.textSecondary)
        }
    }
}
