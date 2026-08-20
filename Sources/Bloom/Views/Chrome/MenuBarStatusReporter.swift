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

        // One observable set on `AppModel`, so this is a real dependency rather than a walk of a
        // dictionary nothing is watching. See `AppModel.runningWorkspaceIDs`.
        let running = app.runningAgentCount
        // The same figure the Dock badge is drawn from, deliberately. "Unread" has one definition
        // in this app and `DockBadge` owns it.
        let unread = DockBadge.unreadCount(in: app.workspaces, isRunning: app.isRunning)
        // The other observable set. See `AppModel.waitingWorkspaceIDs` for why this cannot be
        // derived by walking the models.
        let waiting = app.waitingCount

        return content
            .onChange(of: isEnabled, initial: true) { _, enabled in
                MenuBarStatusItem.shared.setEnabled(enabled, app: app)
                MenuBarStatusItem.shared.setRunningCount(app.runningAgentCount)
                MenuBarStatusItem.shared.setUnreadCount(
                    DockBadge.unreadCount(in: app.workspaces, isRunning: app.isRunning)
                )
                MenuBarStatusItem.shared.setWaitingCount(app.waitingCount)
            }
            .onChange(of: running, initial: true) { _, count in
                MenuBarStatusItem.shared.setRunningCount(count)
            }
            .onChange(of: unread, initial: true) { _, count in
                MenuBarStatusItem.shared.setUnreadCount(count)
            }
            .onChange(of: waiting, initial: true) { _, count in
                MenuBarStatusItem.shared.setWaitingCount(count)
            }
    }
}

extension View {
    func showsAgentsInMenuBar(_ app: AppModel) -> some View {
        modifier(MenuBarStatusReporter(app: app))
    }
}
