import SwiftUI

/// Keeps `AgentActivity` in step with how many agents are actually running.
///
/// A view modifier rather than a `withObservationTracking` loop, because Observation's tracking is
/// one shot and SwiftUI already runs that loop correctly for us.
struct AgentActivityReporter: ViewModifier {
    let app: AppModel

    func body(content: Content) -> some View {
        // Selection is read alongside the count on purpose. `runningAgentCount` walks the model
        // dictionary, which is deliberately outside observation, so a `WorkspaceModel` created
        // after this body last ran would never invalidate it. Selecting a workspace is what
        // creates one, so reading the selection here is what makes the new model's `isRunning`
        // get tracked on the next pass.
        let running = app.runningAgentCount
        let selection = app.selection

        return content
            .onChange(of: running, initial: true) { _, count in
                AgentActivity.shared.setRunningCount(count)
            }
            .onChange(of: selection) { _, _ in
                AgentActivity.shared.setRunningCount(app.runningAgentCount)
            }
    }
}

extension View {
    func reportsAgentActivity(_ app: AppModel) -> some View {
        modifier(AgentActivityReporter(app: app))
    }
}
