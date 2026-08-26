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
    /// The pane's own contextual menu, as an `NSMenu`, for the kinds of tab that take the right
    /// click before SwiftUI is offered it. A browser is one; a terminal answers with its own.
    var paneMenu: (@MainActor () -> NSMenu)?

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

    /// Read for the setup strip's slide. See the `.animation` in `body`.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch tab.kind {
        case .terminal:
            VStack(spacing: 0) {
                // Above the shell rather than inside it. A workspace created to be worked in by
                // hand opens this tab while the setup script is still installing, and until this
                // strip existed nothing on the tab said so. See `WorktreeSetupStrip`.
                WorktreeSetupStrip(readiness: readiness)

                Group {
                    if readyTabID == tab.id {
                        TerminalSplitView(
                            ownerID: tab.id,
                            workspace: model.workspace,
                            repo: model.repo,
                            port: model.port,
                            directory: tab.directory,
                            onCloseTab: { Task { await CenterTabStore.shared.close(tab) } },
                            splitColumn: splitColumn
                        )
                        .id(tab.id)
                    } else {
                        LoadingView("Opening a terminal")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // Gated, because what it drives is `WorktreeSetupStrip`'s `.move(edge: .top)`: the
            // strip slides down and back up, pushing the terminal with it, on every terminal tab
            // opened while setup runs.
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: readiness)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.surfaceSunken)
            .task(id: tab.id) { await prepareTerminal() }

        case .browser:
            BrowserTabView(model: model, tab: tab, paneMenu: paneMenu)
                .id(tab.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        // No `.id(tab.id)`: a review is one long lived tab that is repointed rather than
        // replaced, and rebuilding it on every file would throw away the scroll position of the
        // list it is drawn from. `ReviewPaneView` keys its own content on the path instead.
        case .review:
            ReviewPaneView(model: model, tab: tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        // Keyed on the workspace rather than on the tab, because this one view is reused as the
        // user moves between workspaces and the text in it belongs to whichever workspace it was
        // loaded for. Without the key, walking to the next workspace would leave the previous
        // one's note on screen until its load returned, and a save fired in that window would
        // write one workspace's note over another's.
        case .notes:
            NotesPaneView(model: model)
                .id(model.workspace.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Whether this worktree is finished being built, which is the one thing a shell standing in
    /// it cannot tell you itself. The rule and both sentences are `WorktreeReadiness`, in the
    /// core; the two facts it reads are the live run and the row's own verdict.
    private var readiness: WorktreeReadiness {
        WorktreeReadiness.of(
            isRunningSetup: model.isRunningSetup,
            setupState: model.workspace.setupState
        )
    }

    /// The store a shell's environment is built from, and the workspace's port, which is the one
    /// its setup and run scripts were told to bind. Allocation lives on the model, where
    /// concurrent callers get one block. See `WorkspaceModel.ensurePort`.
    private func prepareTerminal() async {
        TerminalSessionStore.shared.useStore(model.store)
        await model.ensurePort()
        readyTabID = tab.id
    }
}
