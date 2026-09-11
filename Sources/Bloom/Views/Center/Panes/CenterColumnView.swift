import SwiftUI
import BloomCore

/// The centre column: the workspace's tabs, and the panes they are shown in.
///
/// One view for every kind of tab, where there used to be two that each drew their own copy of the
/// strip and swapped places as the selection changed. That swap is what made every hop between a
/// conversation and a terminal rebuild the column and re-run the workspace's arrival work, and it
/// is also what made a chat and a terminal mutually exclusive. A pane holds a tab, so now they are
/// not.
struct CenterColumnView<Model: WorkspacePaneModel>: View {
    @Bindable var model: Model

    var body: some View {
        VStack(spacing: 0) {
            SessionTabsView(model: model)
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    WorkspaceSetupStatusView(model: model, paneHeight: geometry.size.height)
                        .id(model.workspace.id)
                    CenterPanesView(model: model)
                }
            }
        }
        .id(model.paneStores.identity)
        .background(Palette.windowBackground)
        .onChange(of: model.paneStores.center.tabs(for: model.workspace.id).map(\.id)) {
            model.remoteServer?.prepareTabs(for: model.workspace)
        }
        .task(id: model.paneStateID) {
            model.remoteServer?.prepareTabs(for: model.workspace)
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
            model.paneStores.tabs.reconcile(in: model)
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
        model.paneStores.center.load(workspaceID: workspaceID)
        guard let opening = WorkspaceStartMode.consumeOpeningTab(workspaceID: workspaceID, defaults: model.paneStores.defaults) else {
            return
        }
        NewPane.open(opening.pane, in: model) { content in
            if opening == .browser, case .tool(let id) = content,
               let tab = model.paneStores.center.tabs(for: workspaceID).first(where: { $0.id == id }) {
                model.paneStores.center.awaitPreviewAfterSetup(for: tab)
            }
            model.paneStores.tabs.select(content, in: model)
        }
    }
}
