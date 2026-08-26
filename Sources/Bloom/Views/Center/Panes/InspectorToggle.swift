import SwiftUI

/// The right pane's control, at the trailing end of the tab strip that borders it.
///
/// Drawn as the sidebar's toggle is drawn, because the two do the same job to opposite edges of
/// one window and were in two registers: the sidebar's is `NavigationSplitView`'s own toolbar
/// item, which macOS 26 draws as a round glass button, and this was a flat plate that appeared
/// only under the pointer. `.buttonStyle(.glass)` rather than a rim of our own, so it keeps
/// tracking whatever the system does to that shape.
///
/// 28 points across, which is the strip's own control inset taken off its 32 point height. The
/// toolbar's button is about 30 in a 52 point title bar, so this is the nearest the strip has room
/// for rather than a match.
///
/// Still a `Toggle`, so VoiceOver reads it as one. `.accessoryBar` was here because macOS 26 fills
/// a `.button` toggle's on state with the saturated accent, and a pane that is on almost all the
/// time then shouts. What glass does with that state is the one thing here that has to be
/// photographed rather than reasoned about: `PaneTabsGallery` draws both.
///
/// A binding rather than the app model, so the gallery can hold both states on one page.
struct InspectorToggle: View {
    @Binding var isVisible: Bool

    /// The plate, inset from the strip's height by the daylight every control in the row keeps.
    private static let diameter = Metrics.barHeight - 2 * Metrics.spacingTight

    var body: some View {
        Toggle(isOn: $isVisible) {
            Label("Inspector", systemImage: "sidebar.right")
                .labelStyle(.iconOnly)
                .font(Typo.labelEmphasis)
        }
        .toggleStyle(.button)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .frame(width: Self.diameter, height: Self.diameter)
        .frame(height: Metrics.barHeight)
        .padding(.horizontal, Metrics.spacingTight)
        .help(isVisible ? "Hide the changed files" : "Show the changed files")
    }
}
