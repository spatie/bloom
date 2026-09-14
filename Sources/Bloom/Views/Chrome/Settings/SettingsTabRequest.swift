import Foundation

/// Asks the Settings window to show one pane.
///
/// The window picks its pane at launch from `Snapshot.requestedSettingsTab`, which is a command
/// line flag and therefore no use to a menu item. This is the runtime half: the menu bar's
/// "Menubar Settings…" posts a tab, `SettingsView` listens, and the window opens on the pane the
/// person asked for rather than on whichever one they left it on.
enum SettingsTabRequest {
    static let name = Notification.Name("be.spatie.bloom.settings.tab")

    static func post(_ tab: SettingsTab) {
        NotificationCenter.default.post(name: name, object: nil, userInfo: ["tab": tab.rawValue])
    }

    static func tab(in notification: Notification) -> SettingsTab? {
        (notification.userInfo?["tab"] as? String).flatMap(SettingsTab.init(rawValue:))
    }
}
