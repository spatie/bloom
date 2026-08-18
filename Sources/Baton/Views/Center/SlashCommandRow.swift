import SwiftUI

/// One command in the slash menu. A real button, so it answers to VoiceOver and to a click on any
/// part of the row rather than only where the text happens to be.
struct SlashCommandRow: View {
    var command: SlashCommand
    var isSelected: Bool
    var onPick: @MainActor () -> Void
    var onHover: @MainActor () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: Metrics.corner) {
                Text("/\(command.name)")
                    .font(Typo.code)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)

                if !command.detail.isEmpty {
                    Text(command.detail)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if command.origin == .project {
                    Chip(text: command.origin.label)
                }
            }
            .padding(.horizontal, Metrics.corner)
            .frame(height: Metrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rowBackground(isSelected: isSelected, isHovered: isHovered)
        .onHover { hovering in
            isHovered = hovering
            if hovering { onHover() }
        }
    }
}
