import SwiftUI

/// One search hit: the workspace name, then the project it belongs to and the branch it is on.
///
/// Two lines rather than one. On one line the project name, the workspace name and the branch all
/// competed for the same width, and the project collapsed to a letter and a half while the name
/// was still elided. The name leads because it is what was searched for; everything that places
/// it sits underneath in one quiet line, which is how Spotlight and Mail lay a result out.
///
/// A `Button` rather than a tapped `HStack`, so keyboard users can reach it and VoiceOver reads it
/// as one actionable row instead of five loose labels.
struct SearchResultRow: View {
    var hit: AppModel.SearchHit
    var isHovered: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.spacingWide) {
                RepoIcon(repo: hit.repo)

                VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                    Text(hit.workspace.name)
                        .font(Typo.bodyEmphasis)
                        .lineLimit(1)

                    HStack(spacing: Metrics.spacingSmall) {
                        Text(hit.repo?.name ?? "Unknown project")
                            .lineLimit(1)

                        Text(verbatim: "·")
                            .accessibilityHidden(true)

                        Text(hit.workspace.branch)
                            .font(Typo.codeTiny)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(Typo.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: Metrics.spacingWide)

                if hit.workspace.hasDiff {
                    DiffStatLabel(
                        additions: hit.workspace.additions,
                        deletions: hit.workspace.deletions,
                        compact: true
                    )
                }
            }
            .padding(.horizontal, Metrics.inset)
            .padding(.vertical, Metrics.spacing)
            // A minimum rather than a fixed height, so a row grows with the user's text size
            // instead of clipping its own contents at larger settings.
            .frame(minHeight: Metrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rowBackground(isSelected: false, isHovered: isHovered)
        .accessibilityInputLabels([hit.workspace.name])
    }
}
