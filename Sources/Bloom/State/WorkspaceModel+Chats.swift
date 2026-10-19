import AppKit
import Foundation
import SwiftUI
import BloomCore

/// Conversation and tab actions exposed by the workspace model.
extension WorkspaceModel {

    /// The worktree itself: the agent is standing in it. See `WorkspaceModel.attachmentRoot`.
    func attachmentRoot(for chat: SessionID) -> String { workspace.path }
    func adoptActiveChat(_ id: SessionID) {
        if activeSessionID != id { activeSessionID = id }
    }

    /// A tool tab over this worktree, or the setup output of a chat whose CLI is still starting:
    /// a terminal tab is forked with the agent's own command, and until that has run there is
    /// nothing in the pane but the setup log.
    @ViewBuilder
    func toolPane(
        for tab: CenterTab,
        siblings: [PaneContent],
        splitColumn: @escaping @MainActor (SplitAxis, PaneKind) -> Void,
        closeColumn: (@MainActor () -> Void)?,
        paneMenu: (@MainActor () -> NSMenu)?
    ) -> some View {
        if let sessionID = tab.agentSessionID, pendingCLILaunches.contains(sessionID) {
            TerminalView(
                tab: TerminalTab(id: TerminalTabID(tab.id), workspaceID: workspace.id, title: tab.title),
                owner: .workspace(workspace, repo, port: port),
                output: (sessions.first { $0.id == sessionID }?.agentKind ?? .claudeCode)
                    .interactiveSetupOutput(prompt: pendingCLIPrompts[sessionID], log: setupOutput)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ToolPaneView(
                model: self, tab: tab, siblings: siblings,
                splitColumn: splitColumn, closeColumn: closeColumn, paneMenu: paneMenu
            )
        }
    }

    func onColumnAppear() async {
        await onAppear()
    }

    var runScripts: [RunScript] { settings.runScripts }

    func considerRunScriptAutostart() {
        Task { await RunScriptLauncher.shared.considerAutostart(in: self) }
    }

    func pickRunScript(_ script: RunScript) {
        RunScriptLauncher.shared.pick(script, in: self)
    }

    func missingRunScriptFile(_ script: RunScript) -> String? {
        guard let file = settings.scriptFiles[.run(script.id)], file.isMissing else { return nil }
        return file.path
    }

    func openReview() { FileReview.open(in: self) }

    func openNotes() { WorkspaceNotes.open(in: self) }

    func settingsNotices() -> WorkspaceSettingsNotices {
        WorkspaceSettingsNotices(model: self)
    }

    func isRunningChat(_ id: SessionID) -> Bool {
        sessions.first { $0.id == id }.map(isRunning) ?? false
    }

    func closeChat(_ session: Session) {
        CloseSessionAlert.shared.close(session, in: self)
    }

    /// The title alone, and read back afterwards. The value the strip was drawn from was read
    /// before the rename and a running agent has been writing its own columns into that row since,
    /// one of which is the id `--resume` needs.
    func renameChat(_ session: Session, to title: String) {
        guard let store else { return }
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session.with { $0.title = title }
        }
        Task {
            try? await store.updateSessionPreferences(id: session.id, title: title)
            await reloadSessions()
        }
    }

    func reorderChats(to order: [SessionID]) {
        reorderSessions(to: order)
    }

    func runScript(id: String) -> RunScript? {
        settings.runScripts.first { $0.id == id }
    }

    func transcriptMemory(pane: String) -> TranscriptPaneMemory {
        TranscriptPaneMemory(
            pane: pane,
            read: { [weak self] session in self?.panePosition(pane: pane, session: session) },
            write: { [weak self] state, session in self?.rememberPanePosition(state, pane: pane, session: session) }
        )
    }

    func chatLayer(for transcript: TranscriptModel) -> WorkspaceChatLayer {
        WorkspaceChatLayer(transcript: transcript, model: self)
    }
}
