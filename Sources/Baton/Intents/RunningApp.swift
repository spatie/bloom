import AppKit
import Foundation

/// The one route from an intent into the running app.
///
/// An intent is performed inside Baton's own process, but not necessarily inside a Baton that has
/// finished launching: the system starts the app to run the intent, and `perform` can be called
/// while the window is still being built. Every request here goes through the same notifications
/// the deep link and the dock menu already use, so an intent is one more caller of Baton's
/// existing outside-in entry points rather than a second owner of its state.
@MainActor
enum RunningApp {
    /// True once there is a window whose content is on screen.
    ///
    /// The handlers these requests reach are installed by `RootView`, which only exists once the
    /// scene has been built. Posting before then puts a notification on the floor and leaves the
    /// intent waiting for something that will never happen.
    static func waitUntilReady(timeout: Duration = .seconds(20)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if hasWindow { return true }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return hasWindow
    }

    /// Hands the app a `baton://` link, which is the entry point it already uses for creating a
    /// workspace from outside. Posted rather than opened through `NSWorkspace`, because the URL
    /// would take a round trip through LaunchServices only to arrive back in this process as the
    /// same notification.
    static func open(_ url: URL) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .batonHandleURL, object: url)
    }

    /// Selects a workspace in the window, the same way a click in the dock menu does.
    static func select(workspaceID: String) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .batonOpenWorkspace, object: workspaceID)
    }

    /// The menu bar extra and any panel put windows on `NSApp` too, and neither of them carries
    /// the handlers, so the test is for a real titled window rather than for any window at all.
    private static var hasWindow: Bool {
        NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) && $0.canBecomeMain }
    }
}
