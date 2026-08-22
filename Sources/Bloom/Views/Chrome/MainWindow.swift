import AppKit

/// The one way the app raises its main window from outside a scene.
///
/// `NSApp.windows.first` is not it: with About or Settings open, first is whichever panel is in
/// front, so a `bloom://` link or a notification click raised the About window instead, and with
/// the main window closed the `OpenWorkspaceNotification` posted next landed on a torn-down
/// RootView and the deep link was dropped. `canBecomeMain` is what separates the main window
/// from the panels, which cannot.
enum MainWindow {
    @MainActor
    static func raise() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }
}
