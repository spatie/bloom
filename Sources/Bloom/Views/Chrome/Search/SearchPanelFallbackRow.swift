import SwiftUI
import BloomCore

/// One of the two rows under a search that matched nothing.
///
/// It prints the key of the menu item it is a shortcut to, exactly as a command row does, because
/// it is one: Start a Workspace is Cmd+N in File and Search is Shift+Cmd+F in Edit. Nothing in the
/// panel is reachable only from the panel.
struct SearchPanelFallbackRow: View {
    var fallback: SearchPanelFallback
    var isSelected: Bool
    var onPick: @MainActor () -> Void
    var onHover: @MainActor () -> Void

    @Environment(\.controlActiveState) private var activeState
    @State private var isHovered = false

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: Metrics.spacingWide) {
                Image(systemName: symbol)
                    .font(Typo.labelEmphasis)
                    .foregroundStyle(quiet)
                    .frame(width: Metrics.repoIcon)

                Text(fallback.title)
                    .font(Typo.body)
                    .foregroundStyle(loud)
                    .lineLimit(1)

                Spacer(minLength: Metrics.gutter)

                Text(MenuBarCatalogue[fallback.action].keyText)
                    .font(Typo.caption)
                    .foregroundStyle(quiet)
            }
            .searchPanelRowPadding()
            .padding(.vertical, Metrics.spacingSmall)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(fallback.title)
        .searchPanelRowPlate(isSelected: isSelected, isHovered: isHovered)
        .onHoverChange { hovering in
            isHovered = hovering
            if hovering { onHover() }
        }
    }

    private var symbol: String {
        switch fallback {
        case .startWorkspace: "plus.square.on.square"
        case .searchHome: "house"
        }
    }

    private var loud: Color {
        isEmphasized ? Palette.selectedEmphasizedText : Palette.textPrimary
    }

    private var quiet: Color {
        isEmphasized ? Palette.selectedEmphasizedText.opacity(0.76) : Palette.textSecondary
    }

    private var isEmphasized: Bool {
        isSelected && activeState != .inactive
    }
}
