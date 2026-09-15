import SwiftUI
import BloomCore

/// Keep the object being reviewed visible above its files, including the comparison used for
/// merges. These are immutable snapshots, so no checkout or worktree action belongs here.
struct CommitReviewHeader: View {
    let commit: BranchCommit

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            Text(commit.subject).font(Typo.heading).textSelection(.enabled)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Metrics.spacingSmall) { metadata }
                VStack(alignment: .leading, spacing: 2) { metadata }
            }
            .font(Typo.caption).foregroundStyle(Palette.textSecondary)
            if !commit.body.isEmpty {
                Text(commit.body).font(Typo.caption).textSelection(.enabled)
                    .lineLimit(4).help(commit.body)
            }
            Text(commit.parents.count > 1
                 ? "Changes against the first parent · Read-only"
                 : "Changes introduced by this commit · Read-only")
                .font(Typo.micro).foregroundStyle(Palette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(InspectorLayout.inset)
        .background(Palette.surfaceSunken)
    }

    @ViewBuilder private var metadata: some View {
        Text(commit.abbreviated).monospaced().textSelection(.enabled).help(commit.sha)
        Text(commit.author)
        Text(commit.date, format: .dateTime.year().month(.abbreviated).day().hour().minute())
    }
}
