import SwiftUI
import BloomCore

/// One menu bar item in the panel: what it is called, and which key it carries.
///
/// **Every row prints its key, and "no key" is printed rather than left blank.** Bloom has
/// thirty-nine items carrying a shortcut nobody has memorised and nineteen with none at all, and
/// this is the cheapest teaching surface the app will ever get. A blank slot would say nothing
/// about which of the two a row is.
///
/// **An item that cannot be pressed right now is greyed rather than hidden**, which is the rule the
/// menu bar already keeps and for the same reason: a list that hides what is unavailable teaches
/// nothing about what the app can do. Whether it can be pressed is the live menu's answer, not a
/// rule restated here. See `MainMenuActions`.
struct SearchPanelCommandRow: View {
    var hit: SearchPanelCommandHit
    var isEnabled: Bool
    var isSelected: Bool
    var onPick: @MainActor () -> Void
    var onHover: @MainActor () -> Void

    @Environment(\.controlActiveState) private var activeState
    @State private var isHovered = false

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: Metrics.spacingWide) {
                title
                    .font(Typo.body)
                    .lineLimit(1)

                Spacer(minLength: Metrics.gutter)

                Text(hit.item.keyText)
                    .font(Typo.caption)
                    .foregroundStyle(keyColour)
                    .lineLimit(1)
            }
            .searchPanelRowPadding()
            .padding(.vertical, Metrics.spacingSmall)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(hit.item.title)
        .accessibilityValue(hit.item.key == nil ? SearchPanelCommands.noKey : hit.item.keyText)
        .searchPanelRowPlate(isSelected: isSelected, isHovered: isHovered)
        .onHoverChange { hovering in
            isHovered = hovering
            if hovering { onHover() }
        }
    }

    private var title: Text {
        MatchedRuns.text(hit.item.title, highlights: hit.highlights, loud: loud, quiet: quiet)
    }

    private var loud: Color {
        if !isEnabled { return Palette.textDisabled }
        return isEmphasized ? Palette.selectedEmphasizedText : Palette.textPrimary
    }

    private var quiet: Color {
        if !isEnabled { return Palette.textDisabled }
        return isEmphasized ? Palette.selectedEmphasizedText.opacity(0.76) : Palette.textSecondary
    }

    /// The key is one step quieter than the title in every state, because it is a reminder rather
    /// than the thing being read.
    private var keyColour: Color {
        isEnabled ? quiet : Palette.textDisabled
    }

    private var isEmphasized: Bool {
        isSelected && activeState != .inactive
    }
}
