import SwiftUI

/// One search hit: the project it belongs to, the workspace name, its branch and its diff stat.
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
                RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                    .fill(hit.repo.map { Color(hexString: $0.accent) } ?? Palette.textTertiary)
                    .frame(width: Metrics.swatch, height: Metrics.swatch)
                    .accessibilityHidden(true)

                Text(hit.repo?.name ?? "Unknown project")
                    .font(Typo.body)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .layoutPriority(-1)

                Image(systemName: "chevron.right")
                    .font(Typo.micro)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)

                Text(hit.workspace.name)
                    .font(Typo.bodyEmphasis)
                    .lineLimit(1)

                Spacer(minLength: Metrics.spacingWide)

                Chip(
                    text: hit.workspace.branch,
                    systemImage: "arrow.triangle.branch",
                    monospaced: true
                )

                if hit.workspace.hasDiff {
                    DiffStatLabel(
                        additions: hit.workspace.additions,
                        deletions: hit.workspace.deletions,
                        compact: true
                    )
                }
            }
            .padding(.horizontal, Metrics.inset)
            .frame(height: Metrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rowBackground(isSelected: false, isHovered: isHovered)
        .accessibilityInputLabels([hit.workspace.name])
    }
}
