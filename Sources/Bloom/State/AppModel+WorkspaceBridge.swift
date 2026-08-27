import BloomCore

/// The tools an agent can call back into this window with, and the app work behind each of them.
///
/// The socket itself is `BridgeServer` in the core and its one writer is `bootstrap`, which is why
/// `makeBridge(on:)` hands a server back rather than assigning one. What is here is the other
/// side: the toolbox, and the three things a model is allowed to ask for.
///
/// Every one of these is a request from something that cannot see this window. So each answers in
/// a vocabulary of its own rather than by handing back whatever the app happened to throw:
/// `WorkspaceStartTrouble` is the agent-facing companion of `WorkspaceTrouble`, and it tells a
/// model to stop guessing and get on with its own work rather than telling it which folder to put
/// back.

extension AppModel {
    /// The tools the bridge serves, with the app-side half of `workspace_start` bound in.
    ///
    /// The closure is what crosses the boundary. A bridge handler runs off the main actor on a
    /// background task per connection, and everything that makes a workspace actually run lives
    /// here: the model that streams setup into the transcript and sends the opening turn. So the
    /// tool cannot call `WorkspaceManager.start` itself; it hands an order to this, which hops
    /// back and runs the same sequence the Create sheet runs.
    ///
    /// `select: false` is the one difference from the sheet, and it is the point. A workspace
    /// appearing while somebody is typing in another one must not take the selection out from
    /// under them.
    /// Internal because `makeBridge(on:)` stayed in `AppModel.swift`, next to the `bridge` it
    /// is the one writer of. The toolbox is the half worth having here, with the three methods
    /// behind it.
    ///
    /// Built on top of `BridgeToolbox.standard` rather than by listing its handlers again. They
    /// were written out here as well, and a copy of a list is a copy that drifts: a tool added to
    /// the core toolbox and not to this one would pass every test in the suite, which serves
    /// `.standard`, and never reach the running app.
    func bridgeToolbox() -> BridgeToolbox {
        // One closure for the six browser tools rather than six that would have to agree. What
        // crosses the line is "do this to that pane", and `driveBrowserForBridge` resolves which
        // pane the same way every time. See `BrowserPaneCommanding`.
        let browser: BrowserPaneCommanding = { [weak self] command, workspaceID in
            guard let self else { return .refused("Bloom is still starting up.") }
            return await self.driveBrowserForBridge(command, in: workspaceID)
        }

        return BridgeToolbox(handlers: BridgeToolbox.standard.handlers + [
            WorkspaceStartTool { [weak self] order, project, identity, origin in
                guard let self else { throw AppNotReady.stillStartingUp }
                return try await self.startWorkspaceForBridge(
                    order, in: project, from: identity, origin: origin
                )
            },
            PaneOpenTool { [weak self] order, workspaceID in
                guard let self else { return .refused("Bloom is still starting up.") }
                return await self.openPaneForBridge(order, in: workspaceID)
            },
            PaneSplitTool { [weak self] order, axis, workspaceID in
                guard let self else { return .refused("Bloom is still starting up.") }
                return await self.splitPaneForBridge(order, axis: axis, in: workspaceID)
            },
            PaneCloseTool { [weak self] kind, workspaceID in
                guard let self else { return .refused("Bloom is still starting up.") }
                return await self.closePaneForBridge(kind, in: workspaceID)
            },
            PaneRenameTool { [weak self] title, kind, workspaceID in
                guard let self else { return .refused("Bloom is still starting up.") }
                return await self.renamePaneForBridge(title, kind: kind, in: workspaceID)
            },
            PaneListTool { [weak self] workspaceID in
                guard let self else { return nil }
                return await self.paneCensusForBridge(workspaceID)
            },
            // Two closures rather than one, because the shape is the argument: the listing takes a
            // workspace and gives back a census, so nothing on that path can ask the window to do
            // something, and the selecting one carries the single verb. See `WorkspaceTabListing`.
            WorkspaceTabsTool { [weak self] workspaceID in
                guard let self else { return nil }
                return await self.workspaceTabsForBridge(workspaceID)
            },
            WorkspaceTabSelectTool { [weak self] choice, workspaceID in
                guard let self else { return .refused("Bloom is still starting up.") }
                return await self.selectWorkspaceTabForBridge(choice, in: workspaceID)
            },
            BrowserReadTool(browser),
            BrowserReloadTool(browser),
            BrowserGoTool(browser),
            BrowserScrollTool(browser),
            BrowserScreenshotTool(browser),
            BrowserTextTool(browser),
            WorkspaceMergeTool { [weak self] workspace, pullRequest, method in
                guard let self else {
                    return .refused("Bloom is still starting up. Try again in a moment.")
                }
                return await self.requestMergeForBridge(workspace, pullRequest, method: method)
            },
            // Here rather than in `.standard` because the selection is the window's own and lives
            // nowhere else. The name and the sentence were resolved in the core before this is
            // reached, so all the app does is move the selection.
            RevealTool { [weak self] reveal in
                guard let self else { return .refused("Bloom is still starting up.") }
                return await self.revealForBridge(reveal)
            },
        ])
    }

    /// Point the window at something, because the owner's own chat asked to be shown it.
    ///
    /// The whole of the app side, and it is one assignment on purpose. Everything that could be
    /// got wrong (which workspace a name means, whether the arguments contradict each other, what
    /// to say afterwards) was decided in `RevealChoice` before this is reached, where a test can
    /// read it. What is left is the one thing the core cannot do.
    ///
    /// It refuses a workspace that has gone between the resolve and here, rather than selecting an
    /// id nothing answers to: `selection` would take it, and the window would land on an empty
    /// detail column with a sidebar agreeing with nothing.
    func revealForBridge(_ reveal: RevealPlan) -> RevealOutcome {
        switch reveal.target {
        case .workspace(let id):
            guard workspaces.contains(where: { $0.id == id }) else {
                return .refused("That workspace is not in Bloom any more.")
            }
            selection = .workspace(id)
        case .home(let filter):
            homeFilter = filter
            selection = .home
        }
        return .revealed(reveal.sentence)
    }

    /// Ask a workspace's agent to merge, because something on the bridge asked for it.
    ///
    /// The whole of the app side, and it deliberately does nothing of its own. `requestMerge` is
    /// what the strip's Merge button calls, so the template the owner may have edited in Settings,
    /// Bloom's own merge rules, whatever the project adds to them and the guard that refuses mid
    /// turn are all reached through one path rather than two. Anything this function added would
    /// be a second way to move the same state.
    ///
    /// The chat's title comes back because the tool's answer has to name where to watch the turn,
    /// and `requestMerge` has just made that chat the active one.
    private func requestMergeForBridge(
        _ workspace: Workspace,
        _ pullRequest: PullRequest,
        method: GitHub.MergeMethod
    ) async -> WorkspaceMergeHandoff {
        let model = self.model(for: workspace)
        if let refusal = await model.requestMerge(pullRequest, method: method) {
            return .refused(refusal)
        }
        return .turnBegun(chat: model.activeSession?.title ?? "Merge")
    }

    /// Start a workspace because something on the bridge asked for one, and answer with just
    /// enough to name it.
    ///
    /// Neither the project nor the origin is worked out here any more. `WorkspaceStartTool`
    /// decides both, because it is the half that knows which caller is which: an agent may only
    /// ever be given the project its own workspace is in, and the owner's standalone client names
    /// one out loud from the list Bloom already has. Two callers, one answer, decided once. This
    /// side runs the same sequence the Create sheet runs and nothing else.
    private func startWorkspaceForBridge(
        _ order: AgentWorkspaceOrder,
        in repo: Repo,
        from identity: BridgeIdentity,
        origin: WorkspaceOrigin
    ) async throws -> StartedWorkspaceSummary {
        guard let store else { throw AppNotReady.stillStartingUp }

        // Whatever the calling session runs on, unless the tool was told otherwise. An agent
        // asking for help wants help from the thing it already trusts. A caller with no session is
        // the owner's own client, which has nothing to inherit and gets Bloom's defaults.
        var controls = ComposerControls()
        if let sessionID = identity.sessionID, let session = try await store.session(id: sessionID) {
            controls = ComposerControls(session: session, isFastMode: false, outputStyle: OutputStyle.defaultName)
        }
        if let agent = order.agent {
            controls.agentKind = agent
        }

        // Both halves of the order's source, handed to the same two arguments the create sheet's
        // two tabs fill in. Nothing is decided here: `AgentStartSource` has already found the
        // branch in the project and refused the call if it is not there, so this side is the same
        // pass-through it always was.
        let workspace = try await startWorkspace(
            in: repo,
            prompt: order.prompt,
            baseBranch: order.source.baseBranch,
            branch: nil,
            controls: controls,
            select: false,
            origin: origin,
            name: order.name,
            checkout: order.source.checkout
        )

        return StartedWorkspaceSummary(
            workspaceID: workspace.id,
            name: workspace.name,
            branch: workspace.branch,
            path: workspace.path
        )
    }

    // MARK: - Panes

    /// The live model for the workspace a pane tool is speaking for, or nothing.
    ///
    /// A model reaches for these while a turn is running, which is exactly when a workspace can
    /// have been archived out from under it, so "gone" is a real answer rather than a guard for
    /// tidiness. The sentence is a constant beside it so the two tools cannot describe the same
    /// absence differently.
    /// Internal rather than private because `AppModel+BrowserBridge` asks the same question of
    /// the same workspace, and a second resolver there would be a second sentence for the same
    /// absence.
    func paneTarget(_ workspaceID: WorkspaceID) -> WorkspaceModel? {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return nil }
        return model(for: workspace)
    }

    static let noWorkspaceForPane =
        "That workspace is not open in Bloom any more, so there is nowhere to put a pane."

    /// `pane_open`, through the same door the tab strip's `+` menu uses.
    ///
    /// `NewPane.open` and not a copy of it: a chat has to be made in the store before it can be a
    /// tab, and a terminal deliberately does not start its shell here. Reusing it is what keeps a
    /// pane an agent asked for identical to one the reader made.
    func openPaneForBridge(_ order: PaneOrder, in workspaceID: WorkspaceID) async -> PaneOutcome {
        guard let model = paneTarget(workspaceID) else { return .refused(Self.noWorkspaceForPane) }
        let tabs = WorkspaceTabsStore.shared
        NewPane.open(order.kind, in: model, url: order.url ?? "", title: order.title) { content in
            // Placed either way, and selected only when asked. A pane opened in the background is
            // still in the strip, which is the whole point of being able to ask for one: the
            // agent has put it within reach without taking the reader out of what they are doing.
            if order.focus {
                tabs.select(content, in: model)
            } else {
                tabs.reveal(content, in: model)
            }
        }
        return .opened(order.confirmation)
    }

    /// `pane_split`, through the same door Cmd+D uses.
    ///
    /// The refusal comes from `PaneSplit`, which is what greys Split Right in the menu, so a pane
    /// the menu will not divide is one this declines with the menu's own reason rather than with a
    /// second opinion.
    func splitPaneForBridge(
        _ order: PaneOrder, axis: SplitAxis, in workspaceID: WorkspaceID
    ) async -> PaneOutcome {
        guard let model = paneTarget(workspaceID) else { return .refused(Self.noWorkspaceForPane) }
        let tabs = WorkspaceTabsStore.shared
        guard let tab = tabs.selectedTab(in: model) else {
            return .refused(
                "There is no tab open in that workspace to split. Use pane_open instead."
            )
        }
        NewPane.open(order.kind, in: model, url: order.url ?? "", title: order.title) { content in
            tabs.split(tab: tab, axis: axis, showing: content)
        }
        let where_ = axis == .horizontal ? "beside" : "below"
        return .opened("Opened \(order.kind.title) \(where_) what was already on screen.")
    }

    /// Which pane of the tab in front a kind names, or the sentence saying why none does.
    ///
    /// One copy for `pane_close` and `pane_rename` rather than two, because both ask the same
    /// question of the same layout and a second reading is how they would come to disagree about
    /// what "the browser" means. `verb` is the only thing that differs, and it is in the refusal
    /// because a model told "nothing was closed" after asking for a rename learns the wrong thing.
    private func paneForBridge(
        _ kind: PaneKind?, in tab: PaneContent, of workspaceID: WorkspaceID, verb: String
    ) -> Result<String, PaneRefusal> {
        let tabs = WorkspaceTabsStore.shared
        guard let kind else { return .success(tabs.focusedPane(of: tab)) }
        let found = tabs.layout(of: tab).panes.first {
            paneKind(of: tabs.content(of: $0, in: tab), in: workspaceID) == kind
        }
        guard let found else {
            return .failure(
                PaneRefusal(
                    "There is no \(kind.title.lowercased()) open in the tab in front. Nothing was "
                        + verb + "."
                )
            )
        }
        return .success(found)
    }

    /// `pane_close`, through the same surgery the pane's own close control uses.
    ///
    /// Two refusals rather than one, because they are different facts and a model that is told
    /// only "no" cannot tell them apart: nothing of that kind is open, and closing this would
    /// leave the column empty.
    func closePaneForBridge(_ kind: PaneKind?, in workspaceID: WorkspaceID) async -> PaneOutcome {
        guard let model = paneTarget(workspaceID) else { return .refused(Self.noWorkspaceForPane) }
        let tabs = WorkspaceTabsStore.shared
        guard let tab = tabs.selectedTab(in: model) else {
            return .refused("There is nothing open in that workspace to close.")
        }

        let layout = tabs.layout(of: tab)
        let pane: String
        switch paneForBridge(kind, in: tab, of: model.workspace.id, verb: "closed") {
        case .failure(let refusal): return .refused(refusal.sentence)
        case .success(let found): pane = found
        }

        // The last one standing stays. A centre column with nothing in it is a window that looks
        // broken, and an agent tidying up after itself must not be able to produce one.
        guard layout.panes.count > 1 else {
            return .refused(
                "That is the only pane open, and Bloom will not leave the centre column empty. "
                    + "Open something else first, or leave this one."
            )
        }

        guard tabs.close(pane: pane, in: tab, of: model.workspace.id) else {
            return .refused("Bloom could not close that pane.")
        }
        return .opened(kind.map { "Closed the \($0.title.lowercased())." } ?? "Closed that pane.")
    }

    /// `pane_rename`, writing the name to whichever of the two places a pane's name lives in.
    ///
    /// There is no one place, and that is the whole of this function. A terminal and a browser are
    /// `CenterTab` rows, renamed through the store the strip's own double click renames through,
    /// which also settles that a browser page may not rename it back. A chat is a `Session` row in
    /// SQLite, and its rename is `SessionTabsView.commitRename` copied deliberately rather than
    /// re-derived: the list is corrected in place so the strip redraws at once, and the write is
    /// `updateSessionPreferences` and its title alone, because a running agent has been writing
    /// its own columns into that row and a whole-value write would carry them back.
    func renamePaneForBridge(
        _ title: String, kind: PaneKind?, in workspaceID: WorkspaceID
    ) async -> PaneOutcome {
        guard let model = paneTarget(workspaceID) else { return .refused(Self.noWorkspaceForPane) }
        let tabs = WorkspaceTabsStore.shared
        guard let tab = tabs.selectedTab(in: model) else {
            return .refused("There is nothing open in that workspace to rename.")
        }

        let pane: String
        switch paneForBridge(kind, in: tab, of: model.workspace.id, verb: "renamed") {
        case .failure(let refusal): return .refused(refusal.sentence)
        case .success(let found): pane = found
        }

        switch tabs.content(of: pane, in: tab) {
        case .tool(let id):
            let centre = CenterTabStore.shared
            guard let target = centre.tabs(for: workspaceID).first(where: { $0.id == id }) else {
                return .refused("That pane is not in the strip any more, so it was not renamed.")
            }
            centre.rename(target, to: title)

        case .chat(let sessionID):
            guard let store,
                  let session = model.sessions.first(where: { $0.id == sessionID })
            else {
                return .refused("That chat is not open any more, so it was not renamed.")
            }
            let updated = session.with { $0.title = title }
            if let index = model.sessions.firstIndex(where: { $0.id == session.id }) {
                model.sessions[index] = updated
            }
            try? await store.updateSessionPreferences(id: session.id, title: title)
            await model.reloadSessions()
        }

        return .opened("Renamed that pane to '\(title)'.")
    }

    /// What a pane is showing, as one of the three kinds a tool may name.
    ///
    /// Nil for a review and for the notes, which is what keeps `pane_close` off them: they are the
    /// two a workspace has exactly one of and they hold the reader's own work rather than the
    /// agent's, so a tool that cannot name them cannot close them.
    private func paneKind(of content: PaneContent, in workspaceID: WorkspaceID) -> PaneKind? {
        switch content {
        case .chat: return .chat
        case .tool(let id):
            let tabs = CenterTabStore.shared.tabs(for: workspaceID)
            guard let tab = tabs.first(where: { $0.id == id }) else { return nil }
            switch tab.kind {
            case .terminal: return .terminal
            case .browser: return .browser
            case .review, .notes: return nil
            }
        }
    }
}
