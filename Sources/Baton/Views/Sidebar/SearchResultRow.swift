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
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(hit.repo.map { Color(hexString: $0.accent) } ?? Palette.textTertiary)
                    .frame(width: 9, height: 9)
                    .accessibilityHidden(true)

                Text(hit.repo?.name ?? "Unknown project")
                    .font(Typo.label)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)

                Image(systemName: "chevron.right")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textTertiary)
                    .accessibilityHidden(true)

                Text(hit.workspace.name)
                    .font(Typo.bodyEmphasis)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 8)

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
            .padding(.horizontal, 10)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rowBackground(isSelected: false, isHovered: isHovered)
        .accessibilityInputLabels([hit.workspace.name])
    }
}
