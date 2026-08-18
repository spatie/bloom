import SwiftUI
import BloomCore

/// Keeps the menu bar item in step with the setting that switches it on, with how many agents are
/// running, and with how much of what they finished is still unread.
struct MenuBarStatusReporter: ViewModifier {
    let app: AppModel

    @AppStorage(MenuBarStatusItem.settingKey) private var isEnabled = MenuBarStatusItem.isOnByDefault

    func body(content: Content) -> some View {
        // Before `isEnabled` below is read for the first time. See `SystemDefaults`.
        SystemDefaults.registerOnce()

        // Selection is read for the reason `AgentActivityReporter` spells out: the running count
        // walks a dictionary that is outside observation, and selecting a workspace is what puts
        // a new model into it.
        let running = app.runningAgentCount
        let selection = app.selection
        // The same figure the Dock badge is drawn from, deliberately. "Unread" has one definition
        // in this app and `DockBadge` owns it.
        let unread = DockBadge.unreadCount(in: app.workspaces, isRunning: app.isRunning)

        return content
            .onChange(of: isEnabled, initial: true) { _, enabled in
                MenuBarStatusItem.shared.setEnabled(enabled, app: app)
                MenuBarStatusItem.shared.setRunningCount(app.runningAgentCount)
                MenuBarStatusItem.shared.setUnreadCount(
                    DockBadge.unreadCount(in: app.workspaces, isRunning: app.isRunning)
                )
            }
            .onChange(of: running, initial: true) { _, count in
                MenuBarStatusItem.shared.setRunningCount(count)
            }
            .onChange(of: unread, initial: true) { _, count in
                MenuBarStatusItem.shared.setUnreadCount(count)
            }
            .onChange(of: selection) { _, _ in
                MenuBarStatusItem.shared.setRunningCount(app.runningAgentCount)
                MenuBarStatusItem.shared.setUnreadCount(
                    DockBadge.unreadCount(in: app.workspaces, isRunning: app.isRunning)
                )
            }
    }
}

extension View {
    func showsAgentsInMenuBar(_ app: AppModel) -> some View {
        modifier(MenuBarStatusReporter(app: app))
    }
}
