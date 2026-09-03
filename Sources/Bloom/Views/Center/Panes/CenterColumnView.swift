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
            openStartingPane()
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

    /// Opens the tab a workspace created with "Start with: Terminal" or "Start with: Browser" was
    /// promised.
    ///
    /// This is the consumer `WorkspaceStartMode.consumeOpeningTab` never had. Creating a terminal
    /// workspace wrote the hint, skipped the session and the opening turn, and then nothing read
    /// the hint: the workspace opened on an empty conversation, which is not what the control said
    /// and not what anybody picking it wanted. The tab is opened here rather than at creation
    /// because a tab is a thing the centre column owns, and because the hint has to be consumed
    /// exactly once, on the first open, and never forced in front of an arrangement the user has
    /// since made for themselves.
    ///
    /// Through `NewPane`, which is the door the strip's `+` and every split menu already use, so
    /// a tab a workspace is born on and a tab somebody opens a second later are the same tab.
    private func openStartingPane() {
        let workspaceID = model.workspace.id
        // Idempotent, and first: adding a tab to a workspace whose stored list has not been read
        // back yet would replace that list rather than extend it.
        CenterTabStore.shared.load(workspaceID: workspaceID)
        guard let opening = WorkspaceStartMode.consumeOpeningTab(workspaceID: workspaceID) else {
            return
        }
        // No address for a browser, where the strip's `+` passes the workspace's own dev server.
        // The worktree was cut seconds ago and its setup script may still be running, so the port
        // is answering nothing: an opening tab on a refused connection would be an error page as
        // the first thing a new workspace shows. The address field is where somebody says.
        NewPane.open(opening.pane, in: model) { WorkspaceTabsStore.shared.select($0, in: model) }
    }
}
