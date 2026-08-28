import SwiftUI

/// A window pane control used at either end of the title bar.
///
/// Drawn as the sidebar's control is drawn, because the two do the same job to opposite edges of
/// one window. That reference is `NSToolbarToggleSidebarItemIdentifier`, which the SDK describes
/// as "a standard item configured to send -toggleSidebar: to the firstResponder": a plain action
/// item. `NSSplitViewController` validates it, but validation answers enabled or disabled, so
/// **AppKit gives that control no on state at all.** It is the same quiet round button whether the
/// sidebar is open or shut, and what answers "is the pane there" is the pane, a whole column wide.
///
/// So this is a `Button` rather than a `Toggle`, and it stays one: `GlassButtonStyle` took a
/// `PrimitiveButtonStyleConfiguration`, which carries no on state, so the accent plate a toggle
/// would have wanted could only come from `.toggleStyle(.button)` wrapping it, which no button
/// style can reach. That mattered while there was a plate. There is none now; see `body`.
///
/// The state a `Toggle` used to announce is put back by hand below, because it has to be: a sighted
/// reader has the pane itself, and a VoiceOver user has nothing unless this says so.
///
/// A binding rather than the app model, so the gallery can hold both states on one page.
struct WindowPaneToggle: View {
    enum Edge {
        case leading
        case trailing

        var name: String {
            switch self {
            case .leading: "Sidebar"
            case .trailing: "Inspector"
            }
        }

        var symbol: String {
            switch self {
            case .leading: "sidebar.left"
            case .trailing: "sidebar.right"
            }
        }
    }

    var edge: Edge
    var isVisible: Bool
    var action: @MainActor @Sendable () -> Void
    @State private var isHovered = false

    /// Both controls use the same icon-only geometry at opposite ends of the title bar. A subtle
    /// hover fill gives the pointer a target without leaving permanent circles around the icons.
    var body: some View {
        Button(action: action) {
            Label(edge.name, systemImage: edge.symbol)
                .labelStyle(.iconOnly)
                .font(Typo.labelEmphasis)
                // Full ink when the pane is open, quiet when it is not. The one place the control
                // says anything about its own state, and it is the same two-step the tab strip
                // uses for a selected tab against an unselected one.
                .foregroundStyle(isVisible ? Palette.textPrimary : Palette.textSecondary)
        }
        .buttonStyle(.plain)
        .frame(width: Metrics.barHeight, height: Metrics.barHeight)
        .contentShape(Rectangle())
        .onHoverChange { isHovered = $0 }
        // **The plate is inset inside the slot rather than filling it**, and the two points are
        // measured rather than chosen. `fee6766` read the bottom panel's two controls off a two
        // times capture of the strip: a plate handed the whole 32 point slot ran x=0 to x=32, and
        // the rule that closes the tabs off began on x=32, so the two shapes met with no daylight
        // between them at all. That panel and its controls are gone; this is the only plate left
        // in a strip slot and it keeps the finding. Off every side, so the glyph stays centred.
        .background {
            if isHovered {
                RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                    .fill(Palette.hover)
                    .padding(Metrics.spacingTight)
            }
        }
        // A stable name with a spoken state, rather than a name that changes under the reader: a
        // control called "Show the changed files" one moment and "Hide" the next is a different
        // control every time it is found. The direction is in `help`, which is also the tooltip.
        .accessibilityLabel(edge.name)
        .accessibilityValue(isVisible ? "Shown" : "Hidden")
        .help(help)
    }

    private var help: String {
        switch (edge, isVisible) {
        case (.leading, true): "Hide the sidebar"
        case (.leading, false): "Show the sidebar"
        case (.trailing, true): "Hide the changed files"
        case (.trailing, false): "Show the changed files"
        }
    }
}

/// Kept as a small wrapper for the pane gallery, which presents both inspector states without an
/// app model. The live window uses `WindowPaneToggle` directly in its title bar.
struct InspectorToggle: View {
    @Binding var isVisible: Bool

    var body: some View {
        WindowPaneToggle(edge: .trailing, isVisible: isVisible) {
            isVisible.toggle()
        }
    }
}
