import AppKit
import Foundation
import BloomCore

/// The one route from an intent into the running app.
///
/// An intent is performed inside Bloom's own process, but not necessarily inside a Bloom that has
/// finished launching: the system starts the app to run the intent, and `perform` can be called
/// while the window is still being built. So everything here waits for the window before it asks
/// for anything.
///
/// What an intent asks for is either a notification the deep link and the dock menu already use,
/// or a call straight into `AppModel`, which is the state this process is already running on. An
/// intent is one more caller of Bloom's existing entry points either way, never a second owner of
/// its state.
@MainActor
enum RunningApp {
    /// The state the window is running on, handed over by `BloomAppDelegate` once the scene
    /// exists.
    ///
    /// Weak and explicit, the same bargain `BloomServicesProvider`, `SwitchProbe` and
    /// `NotificationService` already make: an intent runs inside this process, so there is a real
    /// `AppModel` to ask, and reaching it directly is what lets an intent execute the same code a
    /// click in the sheet does. Nothing here may create one or keep one alive.
    private static weak var model: AppModel?

    static func attach(_ model: AppModel) {
        Self.model = model
    }

    /// Starts a workspace the way the create sheet does, and answers with it or with why not.
    ///
    /// This replaced a `bloom://` link and a poll. An intent used to build a URL, hand it to the
    /// window, and then read the database every 400ms for up to sixty seconds looking for a row it
    /// had not seen before, because a URL is one way and there was nothing to return. Two
    /// Shortcuts creating a workspace in one project at the same second could each claim the
    /// other's row, and a failure was an alert on somebody's screen that the Shortcut never heard
    /// about.
    static func startWorkspace(in repo: Repo, prompt: String) async throws -> Workspace {
        guard let model else { throw AppNotReady.stillStartingUp }
        // `MainWindow.raise()`, not `NSApp.windows.first`. That helper exists precisely to
        // replace this pattern and its comment names the bug: with About or Settings open,
        // `first` is whichever panel is in front, so a Shortcut raised the About window. The app
        // delegate was fixed when it was found; Shortcuts and Services were not.
        MainWindow.raise()
        return try await model.startWorkspace(in: repo, prompt: prompt)
    }

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

    /// Hands the app a `bloom://` link, which is the entry point it already uses for creating a
    /// workspace from outside. Posted rather than opened through `NSWorkspace`, because the URL
    /// would take a round trip through LaunchServices only to arrive back in this process as the
    /// same notification.
    static func open(_ url: URL) {
        MainWindow.raise()
        NotificationCenter.default.post(name: .bloomHandleURL, object: url)
    }

    /// Selects a workspace in the window, the same way a click in the dock menu does.
    static func select(workspaceID: WorkspaceID) {
        MainWindow.raise()
        OpenWorkspaceNotification.post(workspaceID)
    }

    /// The menu bar extra and any panel put windows on `NSApp` too, and neither of them carries
    /// the handlers, so the test is for a real titled window rather than for any window at all.
    private static var hasWindow: Bool {
        NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) && $0.canBecomeMain }
    }
}
