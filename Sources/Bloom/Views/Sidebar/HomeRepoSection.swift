import SwiftUI
import BloomCore

/// One project's block on Home: its name, its default branch, what its workspaces add up to, a way
/// to start another one, and a grid of the ones worth showing.
///
/// The totals in the heading are the reason the block is worth grouping at all. A project with
/// eleven workspaces, three of them running and nine hundred lines changed, said none of that when
/// the heading was only a name: the user had to count cards, and the cards below are capped, so
/// counting them gave the wrong answer.
struct HomeRepoSection: View {
    var project: HomeProject
    @Binding var hovered: String?
    var onCreateWorkspace: (Repo) -> Void
    var onSelect: (HomeWorkspace) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.inset) {
            heading
            HomeCardGrid(
                workspaces: project.shown,
                hovered: $hovered,
                onSelect: onSelect
            )
        }
    }

    private var heading: some View {
        HStack(spacing: Metrics.spacing) {
            RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                .fill(Color(hexString: project.repo.accent))
                .frame(width: Metrics.swatch, height: Metrics.swatch)
                .accessibilityHidden(true)

            Text(project.repo.name)
                .font(Typo.title)
                .foregroundStyle(Palette.textPrimary)
                .accessibilityAddTraits(.isHeader)

            Text(project.repo.defaultBranch)
                .font(Typo.codeTiny)
                .foregroundStyle(Palette.textTertiary)

            Text(verbatim: "·")
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .accessibilityHidden(true)

            totals

            Spacer(minLength: Metrics.spacingWide)

            // "New" is enough beside the project's own name; VoiceOver and Voice Control get
            // the unambiguous version, because out of context "New" names nothing.
            // No `font` of its own, for the reason `HomeWelcomeHeader` gives: a button style
            // already picks the weight and size AppKit uses at its control size, and setting
            // one desynchronises the label from the control drawn around it.
            Button("New", systemImage: "plus") {
                onCreateWorkspace(project.repo)
            }
            .buttonStyle(.borderless)
            .help("New workspace in \(project.repo.name)")
            .accessibilityLabel("New workspace in \(project.repo.name)")
        }
    }

    private var totals: some View {
        HStack(spacing: Metrics.spacing) {
            Text(countText)
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)

            if project.runningCount > 0 {
                Label("\(project.runningCount) running", systemImage: "bolt.fill")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.running)
            }

            if project.additions > 0 || project.deletions > 0 {
                DiffStatLabel(additions: project.additions, deletions: project.deletions)
            }
        }
        // The three readouts are one summary of one project, so they are announced as one phrase
        // rather than as three fragments a VoiceOver user has to reassemble.
        .accessibilityElement(children: .combine)
    }

    /// Says how many exist, not how many are drawn, and admits the difference when the grid is
    /// capped. A heading reading "11 workspaces" over six cards is otherwise a plain lie.
    private var countText: String {
        let total = project.total == 1 ? "1 workspace" : "\(project.total) workspaces"
        return project.isTruncated ? "\(total), \(project.shown.count) shown" : total
    }
}
