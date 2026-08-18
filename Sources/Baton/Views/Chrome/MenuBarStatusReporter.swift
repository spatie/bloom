import SwiftUI

/// Keeps the menu bar item in step with the setting that switches it on and with how many agents
/// are running.
struct MenuBarStatusReporter: ViewModifier {
    let app: AppModel

    @AppStorage(MenuBarStatusItem.settingKey) private var isEnabled = false

    func body(content: Content) -> some View {
        // Selection is read for the reason `AgentActivityReporter` spells out: the running count
        // walks a dictionary that is outside observation, and selecting a workspace is what puts
        // a new model into it.
        let running = app.runningAgentCount
        let selection = app.selection

        return content
            .onChange(of: isEnabled, initial: true) { _, enabled in
                MenuBarStatusItem.shared.setEnabled(enabled, app: app)
                MenuBarStatusItem.shared.setRunningCount(app.runningAgentCount)
            }
            .onChange(of: running, initial: true) { _, count in
                MenuBarStatusItem.shared.setRunningCount(count)
            }
            .onChange(of: selection) { _, _ in
                MenuBarStatusItem.shared.setRunningCount(app.runningAgentCount)
            }
    }
}

extension View {
    func showsAgentsInMenuBar(_ app: AppModel) -> some View {
        modifier(MenuBarStatusReporter(app: app))
    }
}
