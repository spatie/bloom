import Foundation
import BloomCore

/// A code block's Run action belongs to its originating chat, while the shell belongs to the
/// workspace. Switching conversations must not redirect the eventual report to another agent.
extension WorkspaceModel {
    func runInTerminal(_ code: String, sessionID: SessionID, pane: String?) async {
        guard let store,
              let chat = try? await store.session(id: sessionID), chat.archivedAt == nil,
              !TerminalCommandRun.strippingPrompts(code).isEmpty else { return }
        let run = TerminalCommandRun(command: code, directory: workspace.path, databasePath: store.path)
        do {
            try run.prepare()
        } catch {
            app.alert = BloomAlert(title: "The command could not start", message: error.localizedDescription)
            return
        }

        let terminals = TerminalSessionStore.shared
        let tabs = WorkspaceTabsStore.shared
        if let previous = lastTerminalRun,
           terminalRunPaneExists(previous.pane), previous.run.exitStatus() != nil {
            // Reserve before probing across an await, so a second click cannot reuse it too.
            lastTerminalRun = (previous.pane, run)
            if await terminals.retypeIfIdle(run.typedLine, inPane: previous.pane) {
                tabs.reveal(.tool(previous.pane), in: self, focusing: true)
                watchTerminalRun(run, pane: previous.pane, sessionID: sessionID)
                return
            }
        }

        let tab = tabs.entries(in: self).first { tab in
            tabs.layout(of: tab).panes.contains { candidate in
                (pane == nil || candidate == pane) && tabs.content(of: candidate, in: tab) == .chat(sessionID)
            }
        }
        NewPane.open(.terminal, in: self, title: "Run") { [self] content in
            guard case .tool(let terminalPane) = content else { return }
            terminals.run(run.typedLine, inPaneID: terminalPane)
            if let tab, tabs.split(tab: tab, pane: pane, axis: .vertical, showing: content) != nil {
                tabs.reveal(content, in: self, focusing: true)
            } else {
                tabs.select(content, in: self)
            }
            lastTerminalRun = (terminalPane, run)
            watchTerminalRun(run, pane: terminalPane, sessionID: sessionID)
        }
    }

    private func terminalRunPaneExists(_ pane: String) -> Bool {
        CenterTabStore.shared.tabs(for: workspace.id).contains {
            $0.id == pane && $0.kind == .terminal && TerminalSplitStore.shared.panes(of: pane).contains(pane)
        }
    }

    private func watchTerminalRun(_ run: TerminalCommandRun, pane: String, sessionID: SessionID) {
        // Model-owned work, independent of the code block's view lifetime. Closing the terminal
        // stops observation; archiving the chat prevents the report from starting an unseen turn.
        Task { [weak self] in
            while !Task.isCancelled {
                guard self?.terminalRunPaneExists(pane) == true else { return }
                if let status = run.exitStatus() {
                    await self?.sendTerminalRun(run, exitStatus: status, sessionID: sessionID)
                    return
                }
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
    }

    private func sendTerminalRun(_ run: TerminalCommandRun, exitStatus: Int, sessionID: SessionID) async {
        guard let store else { return }
        do {
            let notice = try await run.notice(exitStatus: exitStatus)
            guard let chat = try await store.session(id: sessionID), chat.archivedAt == nil else { return }
            _ = try await store.enqueueDelivery(
                Delivery(targetSessionID: chat.id, kind: .report, crew: notice)
            )
            let transcript = transcript(for: chat)
            await transcript.refreshQueue()
            await transcript.drain()
        } catch {
            app.alert = BloomAlert(title: "The terminal result could not be sent", message: error.localizedDescription)
        }
    }
}
