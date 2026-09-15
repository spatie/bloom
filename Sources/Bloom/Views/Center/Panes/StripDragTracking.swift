import SwiftUI
import BloomCore

/// What one tab of the strip needs to be carried: where it sits, the gesture that picks it up, and
/// how it is drawn while it or a neighbour is in the air.
///
/// A modifier rather than lines repeated on each of the two kinds of tab, because they have to
/// agree exactly. A conversation and a tool tab are drawn by different functions, and a
/// measurement taken in one space with a pointer reported in another would put every tab of one
/// kind at the wrong place.
///
/// Two coordinate spaces, on purpose. The tab is measured in the strip's own row, which scrolls
/// with the tabs, so a measurement and the offset drawn from it cannot drift when the strip is
/// scrolled. The pointer is reported in the column, because once it leaves the strip it is aiming
/// at a pane and the panes are measured there. Sideways travel is a translation and is the same
/// number in either space.
struct StripDragTracking: ViewModifier {
    /// Which tab this is, in the one type that can name a conversation and a tool tab without
    /// throwing away which of the two it is.
    var content: PaneContent
    var carry: TabCarry
    var stripSpace: String
    var columnSpace: String
    /// Off while the tab's name field is open, so dragging across the field selects text.
    var isEnabled: Bool
    var onMeasure: (TabStripDrag.Span) -> Void
    var onChanged: (DragGesture.Value) -> Void
    var onEnded: () -> Void

    /// How far the pointer has to move before a press is a drag rather than a click. AppKit's own
    /// drag threshold is about this, so a click with a slightly unsteady hand still selects.
    private static let threshold: CGFloat = 4

    /// True for as long as the button is down on this tab, which `DragGesture` resets when the
    /// gesture is cancelled as well as when it ends. `onEnded` is not called for a cancelled
    /// gesture, so without this a drag interrupted by the system, a window losing key status or a
    /// sheet arriving, would leave the tab hanging in the air.
    @GestureState private var isPressed = false

    func body(content view: Content) -> some View {
        let isCarried = carry.isCarrying(content)
        let isLifted = isCarried && carry.isInStrip

        view
            .onGeometryChange(for: TabStripDrag.Span.self) { proxy in
                let frame = proxy.frame(in: .named(stripSpace))
                return TabStripDrag.Span(minX: frame.minX, width: frame.width)
            } action: {
                onMeasure($0)
            }
            // A plate under the lifted tab, so what rises is a tab rather than a floating label: an
            // unselected tab has no fill of its own, and a shadow under bare text is a smudge.
            .background {
                if isLifted {
                    Capsule()
                        .fill(Palette.surface)
                        .frame(height: TabItemView.tabHeight)
                        .padding(.horizontal, Metrics.spacingSmall / 2)
                        .elevation(.resting)
                        .allowsHitTesting(false)
                }
            }
            .scaleEffect(isLifted ? 1.03 : 1)
            // Left in its slot and faded once it is out over the panes, which says that letting go
            // now does not move it in the strip, and where it would go back to if it came back.
            .opacity(isCarried && !carry.isInStrip ? 0.45 : 1)
            .offset(x: carry.offset(of: content))
            .zIndex(isCarried ? 1 : 0)
            .simultaneousGesture(
                DragGesture(minimumDistance: Self.threshold, coordinateSpace: .named(columnSpace))
                    .updating($isPressed) { _, pressed, _ in pressed = true }
                    .onChanged(onChanged)
                    .onEnded { _ in onEnded() },
                isEnabled: isEnabled
            )
            .onChange(of: isPressed) { _, pressed in
                guard !pressed else { return }
                // A turn later, because which of the two arrives first on an ordinary release is
                // not something to depend on, and an ordinary release must be let go by `onEnded`
                // rather than cancelled here. By the time this runs, one that ended normally has
                // already put the tab down.
                Task { @MainActor in
                    await Task.yield()
                    if carry.isCarrying(content) { carry.cancel(animation: nil) }
                    carry.gestureEnded()
                }
            }
    }
}
