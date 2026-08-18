import SwiftUI
import BloomCore

/// Keeps `AgentActivity` in step with how many agents are running and how much of what they
/// finished is still unread.
///
/// A view modifier rather than a `withObservationTracking` loop, because Observation's tracking is
/// one shot and SwiftUI already runs that loop correctly for us.
struct AgentActivityReporter: ViewModifier {
    let app: AppModel

    /// Default on. The badge is the one thing Bloom can say from behind another app's window
    /// without asking permission for anything, so it starts switched on and can be turned off.
    @AppStorage(DockBadge.settingKey) private var isBadgeEnabled = true

    /// Default on. See `SleepPrevention`, which owns both the key and the argument for the
    /// default, because the menu bar item offers the same switch and the two must not drift.
    @AppStorage(SleepPrevention.settingKey) private var preventsSleep = SleepPrevention.isOnByDefault

    func body(content: Content) -> some View {
        // Before `preventsSleep` below is read for the first time. See `SystemDefaults`.
        SystemDefaults.registerOnce()

        // Selection is read alongside the count on purpose. `runningAgentCount` walks the model
        // dictionary, which is deliberately outside observation, so a `WorkspaceModel` created
        // after this body last ran would never invalidate it. Selecting a workspace is what
        // creates one, so reading the selection here is what makes the new model's `isRunning`
        // get tracked on the next pass.
        let running = app.runningAgentCount
        let selection = app.selection
        // Reading the array is what subscribes this body to it. Every path that lowers an unread
        // flag goes through `AppModel.markRead`, which writes to the store and reloads, so the
        // badge follows a workspace being read without a poll and without a restart.
        let unread = DockBadge.unreadCount(in: app.workspaces, isRunning: app.isRunning)

        return content
            .onChange(of: running, initial: true) { _, count in
                AgentActivity.shared.setRunningCount(count)
            }
            .onChange(of: unread, initial: true) { _, count in
                AgentActivity.shared.setUnreadCount(count)
            }
            .onChange(of: preventsSleep, initial: true) { _, isOn in
                AgentActivity.shared.setPreventsSleep(isOn)
            }
            .onChange(of: isBadgeEnabled, initial: true) { _, enabled in
                AgentActivity.shared.setBadgeEnabled(enabled)
                AgentActivity.shared.setUnreadCount(
                    DockBadge.unreadCount(in: app.workspaces, isRunning: app.isRunning)
                )
            }
            .onChange(of: selection) { _, _ in
                AgentActivity.shared.setRunningCount(app.runningAgentCount)
                AgentActivity.shared.setUnreadCount(
                    DockBadge.unreadCount(in: app.workspaces, isRunning: app.isRunning)
                )
            }
    }
}

extension View {
    func reportsAgentActivity(_ app: AppModel) -> some View {
        modifier(AgentActivityReporter(app: app))
    }
}
