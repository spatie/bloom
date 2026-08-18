import SwiftUI
import BatonCore

/// What to do next, shown while the user still has almost nothing here.
///
/// Home's first job is a dashboard, but a dashboard of one workspace has nothing to report, and the
/// screen behind that is the one a new user spends the longest looking at. This block is what fills
/// it: not decoration, but the two things that actually make Baton worth having (a second agent
/// running beside the first, and a second project to run them in) with the button that does each,
/// plus the one sentence about worktrees that explains why running several at once is safe.
///
/// It leaves as soon as it is no longer true. Once there are a few workspaces the user has already
/// done both of these, and a permanent "getting started" panel under a working dashboard is the
/// clearest sign an app was never used by the people who wrote it.
struct HomeNextSteps: View {
    var repo: Repo?
    var onCreateWorkspace: () -> Void
    var onAddProject: () -> Void

    /// Narrow enough that all three tiles share one row on the pane Home actually gets, because
    /// a third tile alone on a second row reads as a card that failed to load rather than as the
    /// end of a band. Still adaptive, so a pane dragged down to one tile's width gets one column
    /// instead of three unreadable ones.
    private static let columns = [
        GridItem(.adaptive(minimum: 200, maximum: 400), spacing: Metrics.gutter)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.inset) {
            Text("Get more out of Baton")
                .font(Typo.title)
                .foregroundStyle(Palette.textPrimary)
                .accessibilityAddTraits(.isHeader)

            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: Metrics.gutter) {
                tile(
                    glyph: "square.split.2x1",
                    title: "Run a second agent",
                    message: startMessage,
                    actionTitle: "New workspace",
                    action: onCreateWorkspace
                )

                tile(
                    glyph: "folder.badge.plus",
                    title: "Add another project",
                    message: "Baton works in any git repository on this Mac, and Home keeps them all on one screen.",
                    actionTitle: "Choose a folder",
                    action: onAddProject
                )

                tile(
                    glyph: "arrow.triangle.branch",
                    title: "Everything lands on a branch",
                    message: "A workspace commits to its own branch. Open a pull request from the inspector once you like what the agent did.",
                    actionTitle: nil,
                    action: nil
                )
            }
        }
    }

    /// Named where there is a project to name, because "New workspace" is a different promise from
    /// "New workspace in there-there" when the user has only ever seen one repository.
    private var startMessage: String {
        guard let repo else {
            return "Each workspace gets its own git worktree and its own agent, so two agents never edit the same file."
        }
        return "Start another workspace in \(repo.name). It gets its own git worktree and its own agent, so the two never edit the same file."
    }

    @ViewBuilder
    private func tile(
        glyph: String,
        title: String,
        message: String,
        actionTitle: String?,
        action: (() -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingWide) {
            Label(title, systemImage: glyph)
                .font(Typo.labelEmphasis)
                .foregroundStyle(Palette.textPrimary)

            Text(message)
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
            }
        }
        .padding(Metrics.inset)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
        .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.corner))
    }
}
