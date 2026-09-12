import BloomCore

/// The app half of terminal_start and the three terminal control tools.
extension AppModel {
    /// Terminal tabs in the order the reader meets them in the strip. An internally split terminal
    /// is still one tab and the tool acts on whichever shell inside it currently has focus.
    func terminalTabs(in model: any WorkspacePaneModel) -> [CenterTab] {
        let tabs = model.paneStores.tabs
        let centre = model.paneStores.center
        var found: [CenterTab] = []

        for entry in tabs.entries(in: model) {
            for pane in tabs.layout(of: entry).panes {
                guard case .tool(let id) = tabs.content(of: pane, in: entry),
                      let tab = centre.tabs(for: model.workspace.id).first(where: { $0.id == id }),
                      tab.kind == .terminal else { continue }
                found.append(tab)
            }
        }
        return found
    }

    func terminalNumbers(in model: any WorkspacePaneModel) -> [String: Int] {
        var numbers: [String: Int] = [:]
        for (index, tab) in terminalTabs(in: model).enumerated() { numbers[tab.id] = index + 1 }
        return numbers
    }

    func startTerminalForBridge(
        _ order: TerminalStartOrder, in workspaceID: WorkspaceID
    ) async -> PaneOutcome {
        guard let model = paneTarget(workspaceID) else { return .refused(Self.noWorkspaceForPane) }
        let tabs = model.paneStores.tabs
        var opened: CenterTab?

        NewPane.open(.terminal, in: model, title: order.title) { content in
            guard case .tool(let id) = content,
                  let tab = model.paneStores.center.tabs(for: workspaceID).first(where: { $0.id == id })
            else { return }

            opened = tab
            if order.focus {
                tabs.select(content, in: model)
            } else {
                tabs.reveal(content, in: model)
            }

            guard model.remoteServer == nil else { return }
            let sessions = TerminalSessionStore.shared
            sessions.run(order.command, inPaneID: tab.id)
            _ = sessions.terminal(
                for: TerminalTab(
                    id: TerminalTabID(tab.id), workspaceID: workspaceID, title: tab.title
                ),
                workspace: model.workspace,
                repo: model.repo,
                port: model.port,
                directory: tab.directory
            )
        }

        guard let opened else {
            return .refused("Bloom could not create the terminal tab.")
        }
        if let server = model.remoteServer {
            guard server.selectedWorkspace?.id == workspaceID else { return .refused("That remote workspace is no longer selected.") }
            do {
                let view = try await server.terminal(named: server.terminalName(for: opened))
                guard server.selectedWorkspace?.id == workspaceID, !Task.isCancelled else { return .refused("The workspace changed before its terminal was ready.") }
                // The normal remote terminal owns SSH/WebSocket input; this never starts a local shell.
                view.send(txt: order.command + "\r")
            } catch { return .refused(error.localizedDescription) }
        }
        try? await Task.sleep(for: .milliseconds(180))
        let position = order.focus ? "and brought it to the front" : "in the background"
        return .opened(
            "Opened terminal '\(opened.title)' \(position) and sent the command. Call "
                + "terminal_read before reporting that it started successfully."
        )
    }

    func driveTerminalForBridge(
        _ command: TerminalBridgeCommand, in workspaceID: WorkspaceID
    ) async -> TerminalPaneAnswer {
        guard let model = paneTarget(workspaceID) else { return .refused(Self.noWorkspaceForPane) }
        guard let census = await paneCensusForBridge(workspaceID) else {
            return .refused(Self.noWorkspaceForPane)
        }
        let reports = census.entries.compactMap(\.terminal)

        let chosen: TerminalPaneReport
        switch TerminalPaneChoice.choose(
            number: command.number, among: reports, tool: command.toolName
        ) {
        case .failure(let refusal): return .refused(refusal.sentence)
        case .success(let report): chosen = report
        }

        let tabs = terminalTabs(in: model)
        guard chosen.number <= tabs.count else {
            return .refused("That terminal has been closed. Call pane_list again.")
        }
        let tab = tabs[chosen.number - 1]
        if let server = model.remoteServer {
            guard let view = server.liveTerminal(named: server.terminalName(for: tab), workspaceID: workspaceID) else {
                return .refused("That terminal has not started. Open it or use terminal_start first.")
            }
            switch command {
            case .read(_, let lines):
                return .output(view.renderedOutput(lines: lines), terminal: chosen.number, name: chosen.name, live: view.hasLiveConnection)
            case .write(_, let text, let submit):
                guard view.hasLiveConnection else { return .refused("That terminal is disconnected. Reconnect it before sending input.") }
                view.send(txt: text + (submit ? "\r" : ""))
                return .told("Sent input to terminal \(chosen.number). Use terminal_read to check the result.")
            case .key(_, let key):
                guard view.hasLiveConnection else { return .refused("That terminal is disconnected. Reconnect it before sending input.") }
                view.send(key.bytes)
                return .told("Sent \(key.rawValue) to terminal \(chosen.number).")
            }
        }
        let paneID = TerminalSplitStore.shared.layout(for: tab.id).focus
        let sessions = TerminalSessionStore.shared

        switch command {
        case .read(_, let lines):
            guard let output = sessions.output(paneID: paneID, lines: lines) else {
                return .refused(
                    "Terminal \(chosen.number) has no live shell in this launch yet. Bring its "
                        + "tab to the front, or use terminal_start to open and start a new one."
                )
            }
            return .output(
                output.text, terminal: chosen.number, name: chosen.name, live: output.live
            )

        case .write(_, let text, let submit):
            guard sessions.write(text, submit: submit, paneID: paneID) else {
                return .refused("Terminal \(chosen.number)'s shell is not running.")
            }
            let ending = submit ? " and pressed Enter" : ""
            return .told(
                "Typed into terminal \(chosen.number), '\(chosen.name)'\(ending). Read it with "
                    + "terminal_read to see what happened."
            )

        case .key(_, let key):
            guard sessions.send(key, paneID: paneID) else {
                return .refused("Terminal \(chosen.number)'s shell is not running.")
            }
            return .told(
                "Sent \(key.rawValue) to terminal \(chosen.number), '\(chosen.name)'."
            )
        }
    }
}
