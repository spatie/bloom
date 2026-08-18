import AppKit
import SwiftUI

/// Paints the title bar in Bloom's own chrome colour.
///
/// The toolbar is `.unified`, so AppKit draws the whole title bar strip with a window material
/// that blends with the desktop behind the window. That is right for an app whose surfaces are
/// the system's, and wrong for one with a ramp of its own: measured against the new palette the
/// strip came out `#282B33`, a neutral grey sitting across the top of a deep blue window, which
/// read as a piece of another application resting on ours.
///
/// `titlebarAppearsTransparent` hands the strip to the window's own background colour, which is
/// the same `Palette.sidebar` the column below it is painted in. That is also what a unified
/// toolbar is meant to look like: one continuous piece of chrome from the traffic lights down the
/// sidebar. The traffic lights, the toolbar items, the proxy icon and the title all stay exactly
/// where AppKit puts them; only the paint behind them changes.
///
/// The colour is an `NSColor` with an appearance provider rather than a resolved value, so the
/// title bar follows a switch between light and dark without this modifier being told about it.
struct WindowChrome: ViewModifier {
    @State private var window: NSWindow?

    func body(content: Content) -> some View {
        content
            .background(WindowAccessor(window: $window))
            .onChange(of: window, initial: true) { _, _ in apply() }
    }

    private func apply() {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Palette.sidebarNSColor
    }
}

extension View {
    func paintsTitleBar() -> some View {
        modifier(WindowChrome())
    }
}
