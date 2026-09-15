import SwiftUI
import BloomCore

/// Where the centre column says it is busy: the decision is `BusySignalPlacement`, and this is the
/// store feeding it what a tab holds and what is running.
///
/// Here rather than in the column or the strip, because the strip's tabs and the column's top edge
/// each draw a half of the answer and they must be handed the same one. The column asks once and
/// passes the value on, so a tab and the top edge can never sweep together while the strip appears
/// or goes.
extension WorkspaceTabsStore {
    func busySignal(
        in model: WorkspaceModel, entries: [PaneContent], selected: PaneContent?, isStripShown: Bool
    ) -> BusySignalPlacement<PaneContent> {
        let tools = CenterTabStore.shared.tabs(for: model.workspace.id)
        return BusySignalPlacement.resolve(
            isStripShown: isStripShown,
            tabs: entries,
            selected: selected,
            panes: { tab in layout(of: tab).panes.map { content(of: $0, in: tab) } },
            isRunning: { content in
                // Exactly what drove the tab's dot before any of this replaced it: a chat's agent
                // (including a CLI agent linked to it, and its subagents), and a run script's
                // command. A plain terminal is never polled and never counts.
                switch content {
                case .chat(let id):
                    model.sessions.first { $0.id == id }.map(model.isRunning) ?? false
                case .tool(let id):
                    tools.first { $0.id == id }.map(RunScriptLauncher.shared.isRunning) ?? false
                }
            }
        )
    }
}
