import SwiftUI
import BloomCore

/// A terminal, a page or a review, filling one pane of the centre column.
///
/// It used to replace the conversation for the whole column, on the grounds that a shell given a
/// third of the height is a shell nobody can read. Panes make that a choice rather than a rule: put
/// a terminal beside a chat and it keeps the full height of its own half.
struct ToolPaneView: View {
    @Bindable var model: WorkspaceModel
    var tab: CenterTab
    /// Splits the centre pane this tab is filling, opening `kind` in the half that opens. Handed
    /// down rather than reached for, because only the pane above knows which pane it is, and a
    /// terminal's contextual menu now offers the same three kinds the centre pane's own menu does.
    var splitColumn: @MainActor (SplitAxis, PaneKind) -> Void

    /// The tab whose shell has had its environment and its port settled, or nothing.
    ///
    /// A shell is forked the first time its view is drawn, with the environment and the port it
    /// keeps for the rest of its life. Both are settled before that happens, or a terminal opened
    /// straight after a relaunch would be handed `BLOOM_PORT=0`.
    ///
    /// A tab id rather than a flag, for the same reason `TranscriptListView.drawnInFull` is one:
    /// this view is reused from one workspace to the next rather than built again, so a flag left
    /// standing from the last workspace's terminal would let the next one's shell be forked before
    /// its port had been allocated. See `CenterPanesView.soloPane`.
    @State private var readyTabID: String?

    var body: some View {
        switch tab.kind {
        case .terminal:
            Group {
                if readyTabID == tab.id {
                    TerminalSplitView(
                        ownerID: tab.id,
                        workspace: model.workspace,
                        repo: model.repo,
                        port: model.port,
                        onCloseTab: { Task { await CenterTabStore.shared.close(tab) } },
                        splitColumn: splitColumn
                    )
                    .id(tab.id)
                } else {
                    LoadingView("Opening a terminal")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.surfaceSunken)
            .task(id: tab.id) { await prepareTerminal() }

        case .browser:
            BrowserTabView(tab: tab)
                .id(tab.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        // No `.id(tab.id)`: a review is one long lived tab that is repointed rather than
        // replaced, and rebuilding it on every file would throw away the scroll position of the
        // list it is drawn from. `ReviewPaneView` keys its own content on the path instead.
        case .review:
            ReviewPaneView(model: model, tab: tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The store a shell's environment is built from, and the workspace's port, which is the one
    /// its setup and run scripts were told to bind. Probing for a free block opens sockets, so it
    /// happens off the main thread.
    private func prepareTerminal() async {
        TerminalSessionStore.shared.useStore(model.store)
        if model.port == 0 {
            model.port = await Task.detached { (try? PortAllocator.allocate(taken: [])) ?? 0 }.value
        }
        readyTabID = tab.id
    }
}
