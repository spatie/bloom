import SwiftUI
import BloomCore

/// One file in the mention menu: the name people recognise, then the folder they only sometimes
/// need, truncated from the front because the end of a path is the part that identifies it.
struct FileMentionRow: View {
    var match: FileMatch
    var isSelected: Bool
    var onPick: @MainActor () -> Void
    var onHover: @MainActor () -> Void

    @Environment(\.controlActiveState) private var activeState

    @State private var isHovered = false

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: Metrics.spacing) {
                Text(match.fileName)
                    .font(Typo.body)
                    .foregroundStyle(isEmphasized ? Palette.selectedEmphasizedText : Palette.textPrimary)
                    .lineLimit(1)

                Text(match.directory)
                    .font(Typo.label)
                    .foregroundStyle(
                        isEmphasized
                            ? Palette.selectedEmphasizedText.opacity(0.75)
                            : Palette.textTertiary
                    )
                    .lineLimit(1)
                    .truncationMode(.head)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.spacing)
            .frame(height: Metrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(match.path)
        // Focused, for the reason spelled out on `SlashCommandRow`.
        .rowBackground(isSelected: isSelected, isHovered: isHovered, isFocused: true)
        .onHover { hovering in
            isHovered = hovering
            if hovering { onHover() }
        }
    }

    /// Whether the row is about to be painted with the accent colour. Both labels set their own
    /// colour, so the inverted foreground `rowBackground` installs never reached them and the
    /// highlighted row used to be black on blue with a near invisible path beside it.
    private var isEmphasized: Bool {
        isSelected && activeState != .inactive
    }
}
