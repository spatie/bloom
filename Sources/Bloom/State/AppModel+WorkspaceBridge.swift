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
    func bridgeToolbox() -> BridgeToolbox {
        BridgeToolbox(handlers: [
            WhoamiTool(),
            ProjectListTool(),
            ProjectAddTool(),
            ProjectHideTool(),
            ProjectUnhideTool(),
            WorkspaceListTool(),
            WorkspaceStartTool { [weak self] order, project, identity, origin in
                guard let self else { throw AppNotReady.stillStartingUp }
                return try await self.startWorkspaceForBridge(
                    order, in: project, from: identity, origin: origin
                )
            },
            WorkspaceMergeTool { [weak self] workspace, pullRequest, method in
                guard let self else {
                    return .refused("Bloom is still starting up. Try again in a moment.")
                }
                return await self.requestMergeForBridge(workspace, pullRequest, method: method)
            },
        ])
    }

    /// Ask a workspace's agent to merge, because something on the bridge asked for it.
    ///
    /// The whole of the app side, and it deliberately does nothing of its own. `requestMerge` is
    /// what the strip's Merge button calls, so the template the owner may have edited in Settings,
    /// the project's `.bloom/merge-instructions.md` and the guard that refuses mid turn are all
    /// reached through one path rather than two. Anything this function added would be a second
    /// way to move the same state.
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

        let workspace = try await startWorkspace(
            in: repo,
            prompt: order.prompt,
            baseBranch: order.baseBranch,
            branch: nil,
            controls: controls,
            select: false,
            origin: origin,
            name: order.name
        )

        return StartedWorkspaceSummary(
            workspaceID: workspace.id,
            name: workspace.name,
            branch: workspace.branch,
            path: workspace.path
        )
    }
}
