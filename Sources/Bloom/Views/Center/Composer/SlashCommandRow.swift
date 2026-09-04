import SwiftUI
import BloomCore

/// One command in the slash menu: what it is called, what it does, and which of its characters the
/// query hit. A real button, so it answers to VoiceOver and to a click on any part of the row
/// rather than only where the text happens to be.
struct SlashCommandRow: View {
    var match: SlashCommandMatch
    var isSelected: Bool
    var onPick: @MainActor () -> Void
    var onHover: @MainActor () -> Void

    @Environment(\.controlActiveState) private var activeState

    @State private var isHovered = false

    private var command: SlashCommand { match.command }

    var body: some View {
        Button(action: onPick) {
            HStack(alignment: .top, spacing: Metrics.spacing) {
                VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                    HStack(spacing: Metrics.spacing) {
                        name
                            .font(Typo.codeSmall)
                            .lineLimit(1)
                            .layoutPriority(1)

                        Spacer(minLength: 0)

                        if let badge = command.badge {
                            Chip(text: badge)
                        }
                    }

                    if !command.detail.isEmpty {
                        Text(command.detail)
                            .font(Typo.caption)
                            .foregroundStyle(detailColour)
                            .lineLimit(3)
                            .truncationMode(.tail)
                    }
                }
            }
            .padding(.horizontal, Metrics.spacing)
            .padding(.vertical, Metrics.spacingSmall)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("/\(command.name)")
        // Focused, because this menu really is driven by the arrow keys while the composer
        // holds the keyboard, which is the one case AppKit paints in the accent.
        .rowBackground(isSelected: isSelected, isHovered: isHovered, isFocused: true)
        .onHover { hovering in
            isHovered = hovering
            if hovering { onHover() }
        }
    }

    /// The name, with the characters the query actually matched carried at full weight and colour
    /// and the rest stepped back.
    ///
    /// The drawing itself is `MatchedRuns`, because the search panel draws a workspace name and a
    /// command title exactly the same way and two copies of it would be two answers to "which
    /// characters matched". What stays here is the `/`, which is this menu's alone, and the two
    /// colours, which depend on whether the row is a skill.
    private var name: Text {
        var runs = LocalizedStringKey.StringInterpolation(literalCapacity: 0, interpolationCount: 0)
        runs.appendInterpolation(Text("/").foregroundStyle(quiet))
        MatchedRuns.append(
            command.name, highlights: match.highlights, loud: loud, quiet: quiet, to: &runs
        )
        return Text(LocalizedStringKey(stringInterpolation: runs))
    }

    private var loud: Color {
        if isEmphasized { return Palette.selectedEmphasizedText }
        return command.kind == .skill ? Palette.accent : Palette.textPrimary
    }

    private var quiet: Color {
        if isEmphasized { return Palette.selectedEmphasizedText.opacity(0.72) }
        return command.kind == .skill ? Palette.accent.opacity(0.76) : Palette.textSecondary
    }

    private var detailColour: Color {
        isEmphasized
            ? Palette.selectedEmphasizedText.opacity(0.88)
            : Palette.textPrimary.opacity(0.68)
    }

    /// See `FileMentionRow`: the labels set their own colour, so they have to know when the row
    /// underneath them has gone accent coloured or they stay unreadable on it.
    private var isEmphasized: Bool {
        isSelected && activeState != .inactive
    }
}
