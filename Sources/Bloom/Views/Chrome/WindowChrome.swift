import AppKit
import SwiftUI

/// Paints the title bar in Bloom's own chrome colour, and puts the workspace's own strip in it.
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
///
/// The trailing end of the same strip is `TitleBarStrip`, added as a title bar accessory. See
/// that file for why an accessory rather than content drawn under a transparent title bar.
struct WindowChrome: ViewModifier {
    /// Handed in rather than read from the environment. This modifier is applied OUTSIDE the
    /// `.environment(model)` that wraps the window's content, so it is an ancestor of the value
    /// rather than a descendant of it, and reading it there is a crash rather than a nil. Its
    /// neighbours in `BloomApp` take the model the same way for the same reason.
    let app: AppModel

    @State private var window: NSWindow?
    @State private var strip: TitleBarStripController?

    func body(content: Content) -> some View {
        content
            .background(WindowAccessor(window: $window))
            .onChange(of: window, initial: true) { _, _ in apply() }
    }

    private func apply() {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Palette.sidebarNSColor
        addStrip(to: window)
    }

    private func addStrip(to window: NSWindow) {
        // The window is checked as well as our own state. A `@State` that comes back empty because
        // the scene was rebuilt would otherwise put a second strip in the same title bar.
        guard strip == nil,
              !window.titlebarAccessoryViewControllers.contains(where: { $0 is TitleBarStripController })
        else { return }
        // Measured before the accessory is added, because `contentLayoutRect` is what the title
        // bar leaves over and an accessory of our own would then be measuring itself.
        let height = window.frame.height - window.contentLayoutRect.height
        guard height > 0 else { return }

        let controller = TitleBarStripController(app: app, height: height)
        window.addTitlebarAccessoryViewController(controller)
        strip = controller
    }
}

extension View {
    func paintsTitleBar(_ app: AppModel) -> some View {
        modifier(WindowChrome(app: app))
    }
}
