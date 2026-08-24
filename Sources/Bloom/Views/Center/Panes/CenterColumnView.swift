import SwiftUI
import BloomCore

/// The centre column: the workspace's tabs, and the panes they are shown in.
///
/// One view for every kind of tab, where there used to be two that each drew their own copy of the
/// strip and swapped places as the selection changed. That swap is what made every hop between a
/// conversation and a terminal rebuild the column and re-run the workspace's arrival work, and it
/// is also what made a chat and a terminal mutually exclusive. A pane holds a tab, so now they are
/// not.
struct CenterColumnView: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            SessionTabsView(model: model)
            CenterPanesView(model: model)
        }
        .background(Palette.windowBackground)
        .task(id: model.workspace.id) {
            openStartingTerminal()
            await model.onAppear()
            // Last, and that ordering is the whole of it. `onAppear` does not return until the
            // first visit of a launch has the workspace's sessions in hand, and the tool tabs were
            // read back synchronously above, so this is the one place in the column where both
            // lists are answers rather than silence. Reconciling forgets every pane pointer
            // nothing accounts for, so it ran from the strip's own task and deleted the chat pane
            // of every terminal or browser tab somebody had split, on the first open after each
            // relaunch. `TabReconciliation` refuses an unread list as well, because an ordering
            // that is only correct by inspection is one edit away from being incorrect.
            WorkspaceTabsStore.shared.reconcile(in: model)
        }
    }

    /// Opens the terminal a workspace created with "Opens with: Terminal" was promised.
    ///
    /// This is the consumer `WorkspaceStartMode.consumeOpensOnTerminal` never had. Creating a
    /// terminal workspace wrote the flag, skipped the session and the opening turn, and then
    /// nothing read the flag: the workspace opened on an empty conversation, which is not what the
    /// control said and not what anybody picking it wanted. The tab is opened here rather than at
    /// creation because a tab is a thing the centre column owns, and because the flag has to be
    /// consumed exactly once, on the first open, and never forced in front of an arrangement the
    /// user has since made for themselves.
    private func openStartingTerminal() {
        let workspaceID = model.workspace.id
        // Idempotent, and first: adding a tab to a workspace whose stored list has not been read
        // back yet would replace that list rather than extend it.
        CenterTabStore.shared.load(workspaceID: workspaceID)
        guard WorkspaceStartMode.consumeOpensOnTerminal(workspaceID: workspaceID) else { return }
        let tab = CenterTabStore.shared.add(kind: .terminal, workspaceID: workspaceID)
        WorkspaceTabsStore.shared.select(.tool(tab.id), in: model)
    }
}
