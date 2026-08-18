import SwiftUI
import BatonCore

/// The centre column while a terminal or a browser tab is showing.
///
/// It replaces the conversation rather than sitting under it, because a shell that has been given
/// a third of the height is a shell nobody can read. The tab strip is the same view the
/// conversation draws, in the same place, so switching kinds moves nothing on screen but the
/// content underneath.
struct CenterToolColumn: View {
    @Bindable var model: WorkspaceModel
    var tab: CenterTab

    /// A shell is forked the first time its view is drawn, with the environment and the port it
    /// keeps for the rest of its life. Both are settled before that happens, or a terminal opened
    /// straight after a relaunch would be handed `BATON_PORT=0`.
    @State private var isTerminalReady = false

    var body: some View {
        VStack(spacing: 0) {
            SessionTabsView(model: model)
            content
        }
        .background(Palette.windowBackground)
        // The same work the conversation does on arrival. A workspace whose column opened straight
        // onto a terminal would otherwise never refresh its changed files or clear its unread mark.
        .task(id: model.workspace.id) { await model.onAppear() }
    }

    @ViewBuilder
    private var content: some View {
        switch tab.kind {
        case .terminal:
            Group {
                if isTerminalReady {
                    // SwiftTerm draws its first glyph on the view's own edge, so without this the
                    // shell's prompt sits flush against the tab strip above it and the window edge
                    // to its left. Every terminal on this platform insets its text.
                    TerminalView(
                        tab: TerminalTab(id: tab.id, workspaceID: tab.workspaceID, title: tab.title),
                        workspace: model.workspace,
                        repo: model.repo,
                        port: model.port
                    )
                    .id(tab.id)
                    .padding(Metrics.spacing)
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
