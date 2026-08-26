import BloomCore

/// The app's half of `workspace_tabs` and `workspace_tab_select`: reading the strip as a strip,
/// and clicking one of its tabs on an agent's behalf.
///
/// Beside `AppModel+BrowserBridge.swift` rather than in it, because that file is about panes and
/// about one browser at a time, and this one is about the strip. They share `paneTarget`,
/// `browserNumbers` and the browser report, which is why those three are not private.
///
/// **Nothing here creates anything, and nothing here costs a subprocess or a request**, which is
/// what lets both tools be self-approved. `CenterTabStore.liveBrowser` is asked rather than
/// `browser(for:)`, `TerminalSessionStore.hasShell` rather than `terminal(for:)`, and selecting a
/// tab writes one entry in `WorkspaceTabsStore`. A listing that fetched six pages, or a selection
/// that opened the terminal it was asked to bring forward, would be a tool that acts while
/// claiming to look.
extension AppModel {
    // MARK: - The strip

    /// `workspace_tabs`: every tab of a workspace, in the order the strip draws them.
    func workspaceTabsForBridge(_ workspaceID: WorkspaceID) async -> WorkspaceTabCensus? {
        guard let model = paneTarget(workspaceID) else { return nil }
        return WorkspaceTabCensus(tabs: await tabRows(in: model).map { $0.report })
    }

    /// The strip, with the content each report was built from kept beside it.
    ///
    /// The pairing is what `workspace_tab_select` needs: a report carries a number and a title,
    /// and `WorkspaceTabsStore.select` takes a `PaneContent`. Resolving that back by indexing into
    /// the strip would be right until a tab pointing at an archived chat was dropped from the
    /// listing, at which point every number after it would name the tab next door.
    private func tabRows(
        in model: WorkspaceModel
    ) async -> [(content: PaneContent, report: WorkspaceTabReport)] {
        let tabs = WorkspaceTabsStore.shared
        let entries = tabs.entries(in: model)
        let active = tabs.selectedTab(in: model, entries: entries)
        let numbers = browserNumbers(in: model)

        var rows: [(content: PaneContent, report: WorkspaceTabReport)] = []
        for entry in entries {
            guard let root = await detail(of: entry, in: model, numbers: numbers) else { continue }
            let layout = tabs.layout(of: entry)
            // Only a tab somebody has divided lists its panes. An unsplit tab is one pane holding
            // the content the tab is named after, so listing it would be the same row twice.
            let panes = layout.paneCount > 1
                ? layout.panes.compactMap {
                    pane(tabs.content(of: $0, in: entry), in: model, numbers: numbers)
                }
                : []

            rows.append((
                entry,
                WorkspaceTabReport(
                    number: 0,
                    title: CenterTabStore.shared.title(of: entry, in: model),
                    isActive: entry == active,
                    detail: root,
                    panes: panes
                )
            ))
        }

        // Numbered after the walk rather than during it, so the numbers count the tabs that are
        // reported and not the entries that were looked at. An entry pointing at a chat archived a
        // second ago is dropped above, and a number handed out before that drop would have sent
        // `workspace_tab_select` one tab along the strip.
        for index in rows.indices { rows[index].report.number = index + 1 }
        return rows
    }

    // MARK: - Selecting one

    /// `workspace_tab_select`, through the same door a click on the strip goes through.
    ///
    /// The strip is read again here rather than trusted from the caller's last listing, for the
    /// reason `driveBrowserForBridge` counts the browsers again: a tab closed in between leaves a
    /// number naming something else, and the something else is a tab the reader is looking at.
    ///
    /// `WorkspaceTabsStore.select` and nothing beside it. That writes which tab the workspace is
    /// in and moves the active conversation with it when the tab's focused pane is a chat, which
    /// is exactly what clicking would do, and it writes no pane's content and creates no tab.
    func selectWorkspaceTabForBridge(
        _ choice: WorkspaceTabChoice, in workspaceID: WorkspaceID
    ) async -> WorkspaceTabSelection {
        guard let model = paneTarget(workspaceID) else {
            return .refused(WorkspaceTabTrouble.noWorkspace)
        }
        let rows = await tabRows(in: model)

        let chosen: WorkspaceTabReport
        switch WorkspaceTabChoice.choose(choice, among: rows.map { $0.report }) {
        case .failure(let refusal): return .refused(refusal.sentence)
        case .success(let found): chosen = found
        }
        guard let row = rows.first(where: { $0.report.number == chosen.number }) else {
            return .refused(WorkspaceTabTrouble.noWorkspace)
        }

        // Answered before anything is written, so a tab that is already in front is never
        // reselected. What the model is told is `WorkspaceTabSelection`'s, in the core, where the
        // suite can read it.
        if chosen.isActive { return .alreadyInFront(chosen) }

        WorkspaceTabsStore.shared.select(row.content, in: model)
        return .brought(chosen)
    }

    // MARK: - One tab

    /// The one true thing about what is in a tab, or nothing for a tab pointing at something that
    /// has gone: a chat archived while the strip still held it, or a tool tab closed from under an
    /// arrangement. Dropped rather than reported as an empty row, for the reason `PaneCensus` drops
    /// one: a listing a model reads should hold what is there.
    private func detail(
        of content: PaneContent, in model: WorkspaceModel, numbers: [String: Int]
    ) async -> WorkspaceTabDetail? {
        switch content {
        case .chat(let sessionID):
            guard let session = model.sessions.first(where: { $0.id == sessionID }) else {
                return nil
            }
            var messages = 0
            if let store {
                messages = (try? await store.messageCount(sessionID: sessionID)) ?? 0
            }
            return .chat(
                WorkspaceTabChat(agent: session.agentKind, state: session.state, messages: messages)
            )

        case .tool(let id):
            let centre = CenterTabStore.shared
            guard let tab = centre.tabs(for: model.workspace.id).first(where: { $0.id == id })
            else { return nil }

            switch tab.kind {
            case .terminal:
                return .terminal(
                    WorkspaceTabTerminal(
                        directory: model.workspace.path,
                        // Every pane of the tab, because a split terminal is one tab with two
                        // shells and either of them being alive makes the tab a live one.
                        isLive: TerminalSplitStore.shared.panes(of: tab.id).contains {
                            TerminalSessionStore.shared.hasShell(paneID: $0)
                        }
                    )
                )

            case .review:
                return .review(WorkspaceTabReview(file: tab.path))

            case .notes:
                var characters = 0
                if let store {
                    let note = try? await store.note(workspaceID: model.workspace.id)
                    characters = note?.body.count ?? 0
                }
                return .notes(WorkspaceTabNote(characters: characters))

            case .browser:
                guard let number = numbers[tab.id] else { return nil }
                return .browser(
                    report(tab, number: number, name: centre.displayTitle(of: tab, in: model))
                )
            }
        }
    }

    /// One pane of a split tab, which is the kind, the name and, for a browser, the number the
    /// `browser_` tools take. Everything else about a pane is `pane_list`.
    private func pane(
        _ content: PaneContent, in model: WorkspaceModel, numbers: [String: Int]
    ) -> WorkspaceTabPane? {
        let title = CenterTabStore.shared.title(of: content, in: model)
        switch content {
        case .chat(let sessionID):
            guard model.sessions.contains(where: { $0.id == sessionID }) else { return nil }
            return WorkspaceTabPane(kind: .chat, title: title)

        case .tool(let id):
            let centre = CenterTabStore.shared
            guard let tab = centre.tabs(for: model.workspace.id).first(where: { $0.id == id })
            else { return nil }
            return WorkspaceTabPane(
                kind: PaneCensusKind(tab.kind),
                title: title,
                browser: tab.kind == .browser ? numbers[tab.id] : nil
            )
        }
    }
}
