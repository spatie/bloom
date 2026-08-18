import SwiftUI
import BatonCore

/// One project's block on Home: its name, its default branch, a way to start a workspace in it,
/// and a grid of its most recent workspaces.
struct HomeRepoSection: View {
    var repo: Repo
    var workspaces: [Workspace]
    @Binding var hovered: String?
    var onCreateWorkspace: (Repo) -> Void
    var onSelect: (Workspace) -> Void

    private static let columns = [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: Metrics.gutter)]

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.inset) {
            HStack(spacing: Metrics.spacing) {
                RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                    .fill(Color(hexString: repo.accent))
                    .frame(width: Metrics.swatch, height: Metrics.swatch)
                    .accessibilityHidden(true)
                Text(repo.name)
                    .font(Typo.title)
                    .foregroundStyle(Palette.textPrimary)
                Text(repo.defaultBranch)
                    .font(Typo.codeTiny)
                    .foregroundStyle(Palette.textTertiary)

                Spacer(minLength: Metrics.spacingWide)

                // "New" is enough beside the project's own name; VoiceOver and Voice Control get
                // the unambiguous version, because out of context "New" names nothing.
                Button("New", systemImage: "plus") {
                    onCreateWorkspace(repo)
                }
                .font(Typo.label)
                .buttonStyle(.borderless)
                .help("New workspace in \(repo.name)")
                .accessibilityLabel("New workspace in \(repo.name)")
            }

            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: Metrics.gutter) {
                ForEach(workspaces) { workspace in
                    HomeWorkspaceCard(
                        workspace: workspace,
                        isHovered: hovered == workspace.id,
                        action: { onSelect(workspace) }
                    )
                    .onHoverChange { inside in
                        hovered = inside ? workspace.id : (hovered == workspace.id ? nil : hovered)
                    }
                }
            }
        }
    }
}
