import SwiftUI

/// The right pane's control, at the trailing end of the tab strip that borders it.
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
struct InspectorToggle: View {
    @Binding var isVisible: Bool
    @State private var isHovered = false

    /// **The glass disc came off.** It was `.buttonStyle(.glass)` in a circle, borrowed from the
    /// sidebar's toolbar control on the argument that the two do the same job to opposite edges of
    /// the window. That argument holds in a toolbar, where every control wears a plate and a round
    /// one is the convention. This control is not in a toolbar: it is at the end of a tab strip,
    /// eight points from a `+` that is a bare glyph, so the plate had nothing to belong to and
    /// read as a white disc floating on the strip.
    ///
    /// So it is drawn as its neighbour is drawn, which is the rule the strip already follows: a
    /// borderless glyph in secondary ink, on the strip's own ground, with a hover tint to say it
    /// is pressable. The state it used to carry in a plate is carried by the pane itself, which is
    /// a whole column wide, and by the accessibility value below for a reader who has neither.
    var body: some View {
        Button { isVisible.toggle() } label: {
            Label("Inspector", systemImage: "sidebar.right")
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
        .accessibilityLabel("Inspector")
        .accessibilityValue(isVisible ? "Shown" : "Hidden")
        .help(isVisible ? "Hide the changed files" : "Show the changed files")
    }
}
