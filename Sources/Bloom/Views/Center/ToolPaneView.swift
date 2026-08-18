import SwiftUI
import BloomCore

/// A terminal or a page, filling one pane of the centre column.
///
/// It used to replace the conversation for the whole column, on the grounds that a shell given a
/// third of the height is a shell nobody can read. Panes make that a choice rather than a rule: put
/// a terminal beside a chat and it keeps the full height of its own half.
struct ToolPaneView: View {
    @Bindable var model: WorkspaceModel
    var tab: CenterTab

    /// A shell is forked the first time its view is drawn, with the environment and the port it
    /// keeps for the rest of its life. Both are settled before that happens, or a terminal opened
    /// straight after a relaunch would be handed `BLOOM_PORT=0`.
    @State private var isTerminalReady = false

    var body: some View {
        switch tab.kind {
        case .terminal:
            Group {
                if isTerminalReady {
                    TerminalSplitView(
                        ownerID: tab.id,
                        workspace: model.workspace,
                        repo: model.repo,
                        port: model.port,
                        onCloseTab: { Task { await CenterTabStore.shared.close(tab) } }
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
        isTerminalReady = true
    }
}
