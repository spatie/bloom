import SwiftUI

/// One file in the mention menu: the name people recognise, then the folder they only sometimes
/// need, truncated from the front because the end of a path is the part that identifies it.
struct FileMentionRow: View {
    var match: FileMatch
    var isSelected: Bool
    var onPick: @MainActor () -> Void
    var onHover: @MainActor () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: Metrics.corner) {
                Text(match.fileName)
                    .font(Typo.bodyEmphasis)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)

                Text(match.directory)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.corner)
            .frame(height: Metrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(match.path)
        .rowBackground(isSelected: isSelected, isHovered: isHovered)
        .onHover { hovering in
            isHovered = hovering
            if hovering { onHover() }
        }
    }
}
