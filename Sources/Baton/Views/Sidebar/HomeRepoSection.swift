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

    private static let columns = [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(hexString: repo.accent))
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                Text(repo.name)
                    .font(Typo.title)
                    .foregroundStyle(Palette.textPrimary)
                Text(repo.defaultBranch)
                    .font(Typo.codeTiny)
                    .foregroundStyle(Palette.textTertiary)

                Spacer(minLength: 8)

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

            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 10) {
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
