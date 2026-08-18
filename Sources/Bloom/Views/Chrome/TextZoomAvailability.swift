import AppKit
import Observation

/// What the View menu's three size items are allowed to do right now.
///
/// It exists because a `Commands` body is not a view. `@AppStorage` inside one is inert: the body
/// is evaluated when the state it reads through an `@Observable` moves, and never because a
/// preference did. Measured rather than assumed: with the size items reading `UserDefaults`
/// directly, stepping the conversation all the way to `largest` left "Zoom In" black and "Actual
/// Size" grey, because the menu still held the answers it was built with at launch.
///
/// So the answers live here, on an object the menu observes, and something has to push them. Two
/// things move them, and neither has a notification of its own: a size preference changes, and the
/// keyboard moves between a terminal and everything else. `NSWindow.didUpdateNotification` covers
/// the second. AppKit posts it once per pass of the event loop for each window on screen, which is
/// the same rhythm it validates menus on, so it is the cheapest hook that cannot miss a focus
/// change; the work behind it is a walk up a short responder chain and three comparisons, and
/// nothing is published unless an answer actually changed.
@MainActor
@Observable
final class TextZoomAvailability {
    static let shared = TextZoomAvailability()

    private(set) var canZoomIn = true
    private(set) var canZoomOut = true
    private(set) var canResetSize = false

    private init() {
        for name in [NSWindow.didUpdateNotification, UserDefaults.didChangeNotification] {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { TextZoomAvailability.shared.refresh() }
            }
        }
    }

    private func refresh() {
        // Read before assigning. `@Observable` publishes on every write, equal or not, and this
        // runs on every pass of the event loop: writing unconditionally would rebuild the whole
        // menu bar as fast as the machine can draw it.
        let zoomIn = TextZoom.canZoomIn
        let zoomOut = TextZoom.canZoomOut
        let reset = TextZoom.canResetSize
        if canZoomIn != zoomIn { canZoomIn = zoomIn }
        if canZoomOut != zoomOut { canZoomOut = zoomOut }
        if canResetSize != reset { canResetSize = reset }
    }
}
