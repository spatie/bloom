import Foundation
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
        // One closure for the browser tools rather than one each that would have to agree. What
        // crosses the line is "do this to that pane", and `driveBrowserForBridge` resolves which
        // pane the same way every time. See `BrowserPaneCommanding`.
        let browser: BrowserPaneCommanding = { [weak self] command, workspaceID in
            guard let self else { return .refused("Bloom is still starting up.") }
            return await self.driveBrowserForBridge(command, in: workspaceID)
        }
        let terminal: TerminalPaneCommanding = { [weak self] command, workspaceID in
            guard let self else { return .refused("Bloom is still starting up.") }
            return await self.driveTerminalForBridge(command, in: workspaceID)
        }
        let mailClient: @Sendable () async -> MailpitClient? = {
            await MainActor.run { Mailbox.shared.mailReadClient }
        }

        return BridgeToolbox(handlers: BridgeToolbox.standard.handlers + [
            // The configured port alone could belong to another local SMTP service if our inbox
            // failed to bind. Only the live Mailbox can say this app owns a ready listener.
            MailSendTool {
                await MainActor.run {
                    Mailbox.shared.mailSendPort.map(MailSendTool.Endpoint.init(port:))
                }
            },
            MailListTool(client: mailClient),
            MailReadTool(client: mailClient),
            WorkspaceStartTool(
                start: { [weak self] order, project, identity, origin in
                    guard let self else { throw AppNotReady.stillStartingUp }
                    return try await self.startWorkspaceForBridge(
                        order, in: project, from: identity, origin: origin
                    )
                },
                // A `project_checkout` call whose project already has one: a chat in it, through
                // the same door as `chat_create`.
                addChat: { [weak self] workspaceID, order in
                    guard let self else { return .refused("Bloom is still starting up.") }
                    return await self.createChatForBridge(order, in: workspaceID)
                }
            ),
            ChatCreateTool { [weak self] workspaceID, order in
                guard let self else { return .refused("Bloom is still starting up.") }
                return await self.createChatForBridge(order, in: workspaceID)
            },
            ChatCloseTool { [weak self] workspaceID, sessionID in
                guard let self else { return .refused("Bloom is still starting up.") }
                return await self.closeChatForBridge(sessionID, in: workspaceID)
            },
            ChatRenameTool { [weak self] workspaceID, sessionID, title in
                guard let self else { return .refused("Bloom is still starting up.") }
                return await self.renameChatForBridge(sessionID, to: title, in: workspaceID)
            },
            PaneOpenTool { [weak self] order, workspaceID in
                guard let self else { return .refused("Bloom is still starting up.") }
                return await self.openPaneForBridge(order, in: workspaceID)
            },
            TerminalStartTool { [weak self] order, workspaceID in
                guard let self else { return .refused("Bloom is still starting up.") }
                return await self.startTerminalForBridge(order, in: workspaceID)
            },
            TerminalReadTool(terminal),
            TerminalWriteTool(terminal),
            TerminalSendKeyTool(terminal),
            MediaShowTool { [weak self] order, workspaceID in
                guard let self else { return .refused("Bloom is still starting up.") }
                return self.showMediaForBridge(order, in: workspaceID)
            },
            PaneSplitTool { [weak self] order, axis, anchor, workspaceID in
                guard let self else { return .refused("Bloom is still starting up.") }
                return await self.splitPaneForBridge(order, axis: axis, anchor: anchor, in: workspaceID)
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
            BrowserSnapshotTool(browser),
            BrowserClickTool(browser),
            BrowserFillTool(browser),
            BrowserPressTool(browser),
            BrowserWaitTool(browser),
            BrowserConsoleTool(browser),
            BrowserNetworkTool(browser),
            WorkspaceArchiveTool { [weak self] order in
                guard let self else { return .refused("Bloom is still starting up.") }
                return await self.archiveWorkspaceForBridge(order)
            },
            WorkspaceRestoreTool { [weak self] workspace in
                guard let self else { return .refused("Bloom is still starting up.") }
                return await self.restoreWorkspaceForBridge(workspace)
            },
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
            // The three crew verbs. Every rule about them is in `Crew` and in the tools, which is
            // where a test can read it; what crosses here is the one thing the core cannot do,
            // which is make a chat in this window run a CLI. See `CrewSeam`.
            AgentStartTool { [weak self] order, sessionID, workspaceID in
                guard let self else { return .refused("Bloom is still starting up.") }
                return await self.startCrewForBridge(order, from: sessionID, in: workspaceID)
            },
            AgentSayTool { [weak self] name, text, sessionID, workspaceID in
                guard let self else { return .refused("Bloom is still starting up.") }
                return await self.sayToCrewForBridge(name, saying: text, from: sessionID, in: workspaceID)
            },
            AgentStopTool { [weak self] name, sessionID, workspaceID in
                guard let self else { return .refused("Bloom is still starting up.") }
                return await self.stopCrewForBridge(name, from: sessionID, in: workspaceID)
            },
            // A message to another workspace. The tool has resolved the target, checked who may
            // write to it and recorded the message; only one that may go without the owner reaches
            // this, and the approval card calls the same method for the rest. See
            // `AppModel+WorkspaceMessages`.
            WorkspaceSayTool({ [weak self] message in
                guard let self else { return .refused("Bloom is still starting up.") }
                return await self.deliverWorkspaceMessage(message)
            }),
        ])
    }

    /// Uses the UI lifecycle so tabs, agents, terminals and selection cannot outlive the worktree.
    /// A refusal goes back to the caller instead of asking the user to approve a destructive retry.
    ///
    /// The owner's own client is acted on at once, because it is standing outside every turn. A
    /// workspace's own agent is booked, because it is standing inside the worktree: see
    /// `bookArchiveForBridge` and `WorkspaceArchiveTool`.
    ///
    /// `workspaces` rather than the row the tool read, in both arms. The list is this window's
    /// own, so a workspace that has been archived by hand since the call came in is not in it, and
    /// booking against a row nobody can act on any more would be a request that could only ever be
    /// refused at the owner.
    private func archiveWorkspaceForBridge(_ order: WorkspaceArchiveOrder) async -> WorkspaceArchiveOutcome {
        guard let current = workspaces.first(where: { $0.id == order.workspace.id }) else {
            return .refused("This workspace is no longer active. Refresh workspace_list.")
        }
        guard let sessionID = order.afterTurnOf else {
            return await archiveForBridge(current, review: order.review)
        }
        return bookArchiveForBridge(of: current, after: sessionID, review: order.review)
    }

    /// Confirms that the path the model named is a real image or movie inside its own worktree.
    /// The transcript resolves it again before drawing, which closes the symlink race between the
    /// tool call and a later visit to this row.
    func showMediaForBridge(
        _ order: MediaShowOrder, in workspaceID: WorkspaceID
    ) -> MediaShowOutcome {
        guard let model = paneTarget(workspaceID) else {
            return .refused(Self.noWorkspaceForPane)
        }
        guard let media = WorkspaceMedia.resolve(path: order.path, in: model.workspace.path) else {
            return .refused(
                "That is not an image or video file inside this workspace. Save it in the "
                    + "workspace, then call media_show with that path."
            )
        }
        let noun = media.kind == .image ? "image" : "video"
        return .shown("Showing \(noun) '\(media.relativePath)' inline in the chat.")
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
    /// decides both, because it is the half that knows which caller is which: an agent is given
    /// the project its own workspace is in unless it names another, and the owner's standalone
    /// client always names one, both from the list Bloom already has. Two callers, one answer,
    /// decided once. `repo` is therefore not necessarily the caller's own project. This
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
            // The context window comes with it, because on Codex it is part of what "the thing it
            // already trusts" means: an agent running on a widened window that starts a helper on
            // the catalogue's own would be handing the harder half of its job to the smaller one.
            let contextWindow = CodexContextWindow.normalised(try await store.setting(
                ComposerControls.contextWindowKey(sessionID: sessionID)
            ))
            let codexFastMode = CodexSpeed.override(stored: try await store.setting(CodexSpeed.key(sessionID: sessionID)))
            controls = ComposerControls(
                session: session,
                isFastMode: false,
                outputStyle: OutputStyle.defaultName,
                codexContextWindow: contextWindow,
                codexFastMode: codexFastMode
            )
        }
        controls = try await workspaceControls(for: order, inheriting: controls)

        // Both halves of the order's source, handed to the same two arguments the create window's
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
            checkout: order.source.checkout,
            kind: order.source.kind
        )

        return StartedWorkspaceSummary(
            workspaceID: workspace.id,
            name: workspace.name,
            branch: workspace.branch,
            path: workspace.path
        )
    }

    /// Keeps the backend and model one valid choice. Changing only the backend used to carry the
    /// caller's model across with it, which is how a Codex workspace was started with `opus`.
    private func workspaceControls(
        for order: AgentWorkspaceOrder,
        inheriting inherited: ComposerControls
    ) async throws -> ComposerControls {
        try await agentControls(
            agent: order.agent,
            model: order.model,
            effort: order.effort,
            inheriting: inherited
        )
    }

    /// Applies every agent control the create-workspace composer carries to its first chat. Nil
    /// fields keep the target project's resolved defaults. Backend-specific controls are refused
    /// on a backend that has no corresponding picker rather than accepted and silently ignored.
    private func chatControls(
        for order: ChatCreateOrder,
        inheriting inherited: ComposerControls
    ) async throws -> ComposerControls {
        var controls = try await agentControls(
            agent: order.agent,
            model: order.model,
            effort: order.effort,
            inheriting: inherited
        )

        let modes = order.modes(on: controls.agentKind)
        if let permission = modes.permission {
            guard controls.availablePermissionModes.contains(permission) else {
                throw BridgeAgentControlFailure.unsupportedPermission(permission, agent: controls.agentKind)
            }
            controls.permissionMode = permission
        }
        if let interaction = modes.interaction {
            guard interaction.nearest(on: controls.agentKind) == interaction else {
                throw BridgeAgentControlFailure.unsupportedInteraction(interaction, agent: controls.agentKind)
            }
            if interaction == .plan, !ComposerPlanningSupport.shared.isAvailable {
                throw InteractionModeFailure.unsupported
            }
            controls.interactionMode = interaction
        }
        if let fast = order.fastMode {
            guard controls.agentKind == .claudeCode || controls.agentKind == .codex else {
                throw BridgeAgentControlFailure.unsupportedFastMode(controls.agentKind)
            }
            controls = controls.settingFastMode(fast)
        }
        if let style = order.outputStyle {
            guard controls.offersOutputStyle else {
                throw BridgeAgentControlFailure.unsupportedOutputStyle(controls.agentKind)
            }
            controls.outputStyle = style
        }
        if let contextWindow = order.contextWindow {
            guard controls.offersContextWindow else {
                throw BridgeAgentControlFailure.unsupportedContextWindow(controls.agentKind)
            }
            controls.codexContextWindow = contextWindow
        }
        return controls
    }

    /// Keeps backend, model and effort one valid choice for both workspace and chat creation.
    /// Changing only the backend must not carry the previous backend's model across with it.
    func agentControls(
        agent requestedAgent: AgentKind?,
        model requestedModel: String?,
        effort requestedEffort: String?,
        inheriting inherited: ComposerControls
    ) async throws -> ComposerControls {
        var controls = inherited
        let inheritedAgent = controls.agentKind
        // A caller that names a model and no agent has named an agent, because a model id says
        // which CLI runs it. This used to be free: everything inherited Claude Code, so
        // `workspace_start(model: "opus")` could only mean Claude Code. It stopped being free the
        // moment the Models screen could make Codex the default, which would have turned that
        // same call into "opus is not a Codex model". No list is fetched to answer it: the four
        // families `ClaudeModelRank` knows are what the old reading covered, and anything else
        // stays on the backend that was inherited. See `DefaultBackend`.
        let agent = requestedAgent
            ?? requestedModel.map {
                DefaultBackend.kind(ofModel: $0, running: inheritedAgent, models: [:])
            }
            ?? inheritedAgent
        controls.agentKind = agent

        if agent == .claudeCode {
            // What the CLI lists and the written list both, so an agent that names `opus`, which
            // the CLI lists as `opus[1m]`, is not refused a model the CLI will happily run.
            let models = Set(ComposerOption.models.map(\.id))
                .union(ComposerModelCatalog.shared.options(for: .claudeCode).map(\.id))
            if let model = requestedModel {
                guard models.contains(model) else {
                    throw BridgeAgentControlFailure.invalidModel(
                        model: model,
                        agent: agent,
                        available: models.sorted()
                    )
                }
                controls.model = model
            } else if agent != inheritedAgent {
                controls.model = AppDefaults.fallbackModel
            }
            if let effort = requestedEffort {
                let available = ComposerOption.efforts.map(\.id)
                guard available.contains(effort) else {
                    throw BridgeAgentControlFailure.invalidEffort(
                        effort: effort,
                        model: controls.model,
                        available: available
                    )
                }
                controls.effort = effort
            }
        } else {
            guard let source = AgentModelSource.live(store: store)[agent] else {
                throw BridgeAgentControlFailure.noneAvailable(agent)
            }
            if requestedModel == nil, requestedEffort == nil, agent == inheritedAgent { return controls }

            let models = try await source.models()
            let model = requestedModel ?? (agent == inheritedAgent ? controls.model : nil)
            let chosen = model.flatMap { id in models.first { $0.id == id } }
                ?? AgentModel.selection(requested: requestedModel, from: models)
            guard let chosen else {
                if let requested = requestedModel {
                    throw BridgeAgentControlFailure.invalidModel(
                        model: requested,
                        agent: agent,
                        available: models.filter { !$0.hidden }.map(\.id)
                    )
                }
                throw BridgeAgentControlFailure.noneAvailable(agent)
            }
            controls.model = chosen.id
            if let effort = requestedEffort {
                let available = chosen.supportedEfforts.map(\.id)
                guard available.contains(effort) else {
                    throw BridgeAgentControlFailure.invalidEffort(
                        effort: effort,
                        model: chosen.id,
                        available: available
                    )
                }
                controls.effort = effort
            } else {
                controls.effort = chosen.resolvedEffort(preferring: controls.effort)
            }
        }

        return controls
    }

    // MARK: - Crew

    /// A crew member runs in the caller's own worktree and nowhere else, so a workspace archived
    /// out from under a running turn is a real answer here rather than a guard for tidiness,
    /// exactly as it is for the pane tools. `paneTarget` resolves it, and only the sentence is
    /// this family's own: the pane one talks about panes, and a model told the wrong noun learns
    /// the wrong thing.
    static let noWorkspaceForCrew =
        "That workspace is not open in Bloom any more, so there is no worktree to run a subagent in."

    /// `agent_start`, handed to the model that can actually spawn a CLI.
    ///
    /// The same seam `workspace_start` crosses and for the same reason: everything that makes a
    /// chat run lives on the main actor in `WorkspaceModel`, and a bridge handler runs off it on a
    /// background task per connection. Nothing is decided here. `AgentStartTool` has already put
    /// the name through `Crew.normalisedName` and weighed both the ceiling and the name against
    /// the rows; `startCrewMember` re-checks the one rule a second door must never skip, which is
    /// that a crew member may not start a crew member.
    private func startCrewForBridge(
        _ order: CrewOrder, from sessionID: SessionID, in workspaceID: WorkspaceID
    ) async -> CrewStartOutcome {
        guard let model = paneTarget(workspaceID) else { return .refused(Self.noWorkspaceForCrew) }
        return await model.startCrewMember(order, reportingTo: sessionID)
    }

    /// `agent_say`, in whichever direction the caller is talking. `name` is nil when a crew member
    /// is talking up, which is the one place it has to talk. See `CrewSaying`.
    private func sayToCrewForBridge(
        _ name: String?, saying text: String, from sessionID: SessionID, in workspaceID: WorkspaceID
    ) async -> CrewSayOutcome {
        guard let model = paneTarget(workspaceID) else { return .refused(Self.noWorkspaceForCrew) }
        return await model.sayToCrew(text, to: name, from: sessionID)
    }

    /// `agent_stop`. Only the chat that started a crew member may stop it, and that is enforced by
    /// the lookup rather than by a comparison here: `Store.crew(of:)` answers with one chat's own
    /// crew, so a name belonging to somebody else's simply is not found.
    private func stopCrewForBridge(
        _ name: String, from sessionID: SessionID, in workspaceID: WorkspaceID
    ) async -> CrewStopOutcome {
        guard let model = paneTarget(workspaceID) else { return .refused(Self.noWorkspaceForCrew) }
        return await model.stopCrewMember(named: name, startedBy: sessionID)
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

    /// Adds a chat through the same lifecycle as the `+` menu, without selecting another
    /// workspace in the owner's window. `createChat` also settles the project's current defaults
    /// and any terminal-backed chat before the result is exposed.
    func createChatForBridge(_ order: ChatCreateOrder, in workspaceID: WorkspaceID) async -> ChatCreateOutcome {
        guard let model = paneTarget(workspaceID) else {
            return .refused("That workspace is not open in Bloom any more, so a chat was not created.")
        }
        guard let repo = repo(for: model.workspace) else {
            return .refused("Bloom cannot find that workspace's project any more.")
        }

        let controls: ComposerControls
        do {
            let defaults = try await resolvedControls(for: repo)
            controls = try await chatControls(for: order, inheriting: defaults)
        } catch {
            return .refused(error.readableMessage)
        }

        guard let content = await model.createChat(
            title: order.title,
            controls: controls,
            usesCLI: order.terminalChat,
            message: order.message,
            messageSender: order.messageSender
        ),
              case .chat(let sessionID) = content,
              let session = model.sessions.first(where: { $0.id == sessionID }) else {
            return .refused("Bloom could not create a chat in '\(model.workspace.name)'.")
        }

        // Reveal means it earns its place in the target workspace's strip without taking the
        // selected workspace or tab away from the owner. The session itself is active there, so
        // `workspace_say` immediately after this call has an unambiguous destination.
        WorkspaceTabsStore.shared.reveal(content, in: model)
        return .created(bridgeSummary(session, in: model.workspace))
    }

    /// Closes only a settled chat and leaves at least one top-level conversation behind. Those
    /// two checks are what make this safe to self-approve: a bridge call cannot cut off work in
    /// flight or leave a workspace with no handover destination. `closeSession` keeps the
    /// transcript in Recently Closed and performs all runner, tab and bridge-token cleanup.
    func closeChatForBridge(_ sessionID: SessionID, in workspaceID: WorkspaceID) async -> ChatCloseOutcome {
        guard let model = paneTarget(workspaceID) else {
            return .refused("That workspace is not open in Bloom any more, so no chat was closed.")
        }
        await model.reloadSessions()
        guard let session = model.sessions.first(where: {
            $0.id == sessionID && $0.parentSessionID == nil && $0.sideConversationParentID == nil
        }) else {
            return .refused("That chat is not open in '\(model.workspace.name)' any more. Refresh chat_list.")
        }
        if let refusal = BridgeChatClosure.refusal(
            title: ChatListTool.title(of: session),
            isRunning: model.isRunning(session),
            otherTopLevelChats: TabSet.tabbable(model.sessions).count - 1
        ) {
            return .refused(refusal)
        }

        let summary = bridgeSummary(session, in: model.workspace)
        await model.closeSession(session)
        guard !model.sessions.contains(where: { $0.id == session.id }) else {
            return .refused("Bloom could not close that chat.")
        }
        return .closed(summary)
    }

    /// Renames the row through the same column-only write the tab strip uses. The handler has
    /// already resolved the workspace and chat; this side revalidates both after crossing actors
    /// so a close racing the call cannot rename a stale copy or claim success.
    func renameChatForBridge(
        _ sessionID: SessionID,
        to title: String,
        in workspaceID: WorkspaceID
    ) async -> ChatRenameOutcome {
        guard let model = paneTarget(workspaceID), let store else {
            return .refused("That workspace is not open in Bloom any more, so no chat was renamed.")
        }
        await model.reloadSessions()
        guard let session = model.sessions.first(where: {
            $0.id == sessionID && $0.parentSessionID == nil && $0.sideConversationParentID == nil
        }) else {
            return .refused("That chat is not open in '\(model.workspace.name)' any more. Refresh chat_list.")
        }

        do {
            try await store.updateSessionPreferences(id: session.id, title: title)
        } catch {
            return .refused("Bloom could not rename that chat: \(error.readableMessage)")
        }
        await model.reloadSessions()
        guard let renamed = model.sessions.first(where: { $0.id == session.id }), renamed.title == title else {
            return .refused("Bloom could not rename that chat.")
        }
        return .renamed(chat: bridgeSummary(renamed, in: model.workspace), previousTitle: session.title)
    }

    private func bridgeSummary(_ session: Session, in workspace: Workspace) -> BridgeChatSummary {
        BridgeChatSummary(
            chatID: session.id,
            title: ChatListTool.title(of: session),
            agent: session.agentKind,
            model: session.model,
            effort: session.effort,
            permissionMode: session.permissionMode,
            interactionMode: session.interactionMode,
            workspaceID: workspace.id,
            workspace: workspace.name
        )
    }

    /// `pane_open`, through the same door the title bar's `+` menu uses.
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

private enum BridgeAgentControlFailure: LocalizedError {
    case invalidModel(model: String, agent: AgentKind, available: [String])
    case invalidEffort(effort: String, model: String, available: [String])
    case noneAvailable(AgentKind)
    case unsupportedPermission(PermissionMode, agent: AgentKind)
    case unsupportedInteraction(InteractionMode, agent: AgentKind)
    case unsupportedFastMode(AgentKind)
    case unsupportedOutputStyle(AgentKind)
    case unsupportedContextWindow(AgentKind)

    var errorDescription: String? {
        switch self {
        case let .invalidModel(model, agent, available):
            let choices = available.isEmpty ? "none were reported" : available.joined(separator: ", ")
            return "The model '\(model)' is not available for \(agent.label). Available models: \(choices)."
        case let .invalidEffort(effort, model, available):
            let choices = available.isEmpty ? "none were reported" : available.joined(separator: ", ")
            return "The effort '\(effort)' is not available for '\(model)'. Available efforts: \(choices)."
        case .noneAvailable(let agent):
            return "Bloom could not find an available model for \(agent.label)."
        case let .unsupportedPermission(mode, agent):
            return "The permission mode '\(mode.rawValue)' is not available for \(agent.label)."
        case let .unsupportedInteraction(mode, agent):
            return "The interaction mode '\(mode.rawValue)' is not available for \(agent.label)."
        case .unsupportedFastMode(let agent):
            return "Fast mode is not available for \(agent.label)."
        case .unsupportedOutputStyle(let agent):
            return "Output styles are not available for \(agent.label)."
        case .unsupportedContextWindow(let agent):
            return "A context-window override is not available for \(agent.label)."
        }
    }
}
