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
/// So this is a `Button` rather than a `Toggle`. `.buttonStyle(.glass)` is right for the resting
/// shape and wrong the moment a toggle is on: `GlassButtonStyle` takes a
/// `PrimitiveButtonStyleConfiguration`, which carries no on state, so the accent plate came from
/// `.toggleStyle(.button)` wrapping it, and no button style can reach that. A `Button` has no such
/// wrapper and cannot acquire one.
///
/// 28 points across, the strip's own control inset taken off its 32 point height, against about 30
/// in a 52 point title bar. The nearest the strip has room for.
///
/// The state a `Toggle` used to announce is put back by hand below, because it has to be: a sighted
/// reader has the pane itself, and a VoiceOver user has nothing unless this says so.
///
/// A binding rather than the app model, so the gallery can hold both states on one page.
struct InspectorToggle: View {
    @Binding var isVisible: Bool

    /// The plate, inset from the strip's height by the daylight every control in the row keeps.
    private static let diameter = Metrics.barHeight - 2 * Metrics.spacingTight

    var body: some View {
        Button { isVisible.toggle() } label: {
            Label("Inspector", systemImage: "sidebar.right")
                .labelStyle(.iconOnly)
                .font(Typo.labelEmphasis)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .frame(width: Self.diameter, height: Self.diameter)
        .frame(height: Metrics.barHeight)
        .padding(.horizontal, Metrics.spacingTight)
        // A stable name with a spoken state, rather than a name that changes under the reader: a
        // control called "Show the changed files" one moment and "Hide" the next is a different
        // control every time it is found. The direction is in `help`, which is also the tooltip.
        .accessibilityLabel("Inspector")
        .accessibilityValue(isVisible ? "Shown" : "Hidden")
        .help(isVisible ? "Hide the changed files" : "Show the changed files")
    }
}
