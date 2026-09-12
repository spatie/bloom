import Foundation
import BloomClient

/// The standalone runtime is the single owner of its store and its session runners. Clients
/// request snapshots and commands, never open its SQLite file or launch a second runner.
public actor ServerRuntime {
    public typealias AgentDiscovery = @Sendable (Store) async -> [AgentKind]
    private let installedAgents: AgentDiscovery
    private let authentication: ServerAgentAuthentication.Check
    public typealias RunnerFactory = @Sendable (Session, String, Store) -> any SessionRunner
    private let store: Store
    private let storage: ServerStorageService
    private let makeRunner: RunnerFactory?
    private var bridge: BridgeServer?
    private var bridgeArchives: [SessionID: Task<Void, Never>] = [:]
    let uiBroker = ServerUIBroker()
    private let reviewCache = ServerReviewCache()
    private let repositories = ServerRepositoryResolver()
    private let terminals = ServerTerminalService()
    private let workspaceAdmissions: ServerWorkspaceAdmissions
    private let terminalStreams: ServerTerminalStreams
    private let modelCatalogue = CodexModelCatalog.live()
    private var sessions: [SessionID: ServerSession] = [:]
    private var creating: [SessionID: Task<ServerSession, Error>] = [:]
    private var commands: [UUID: Task<ServerReply, Never>] = [:]
    private var commandOperations: [UUID: ServerOperation] = [:]
    private var stopping: [SessionID: Int] = [:]
    private var closingSessions: Set<SessionID> = []
    private var changingWorkspaces: Set<WorkspaceID> = []
    private var settingUpWorkspaces: Set<WorkspaceID> = []
    private var archivePreviews: [UUID: ServerArchivePreview] = [:]
    private var isClosed = false
    private var shutdownTask: Task<Void, Never>?
    private var promptQueue: ServerPromptQueue?

    public init(store: Store, authentication: @escaping ServerAgentAuthentication.Check = ServerAgentAuthentication.inspect, gatewayGroupID: UInt32? = nil, installedAgents: @escaping AgentDiscovery = ServerAgentAvailability.installed, makeRunner: RunnerFactory? = nil) {
        self.init(store: store, authentication: authentication, gatewayGroupID: gatewayGroupID, installedAgents: installedAgents, makeRunner: makeRunner,
                  workspaceAdmissions: ServerWorkspaceAdmissions())
    }

    init(store: Store, authentication: @escaping ServerAgentAuthentication.Check = ServerAgentAuthentication.inspect, gatewayGroupID: UInt32? = nil, installedAgents: @escaping AgentDiscovery,
         makeRunner: RunnerFactory? = nil, workspaceAdmissions: ServerWorkspaceAdmissions, storageService: ServerStorageService? = nil) {
        self.workspaceAdmissions = workspaceAdmissions
        self.store = store
        storage = storageService ?? ServerStorageService(directory: (store.path as NSString).deletingLastPathComponent)
        self.installedAgents = installedAgents
        self.authentication = authentication
        terminalStreams = ServerTerminalStreams(groupID: gatewayGroupID)
        self.makeRunner = makeRunner
    }

    private func authenticationStatuses(_ agents: [AgentKind], workspace: Workspace? = nil) async -> [AgentAuthenticationStatus] {
        await ServerAgentAuthentication.checkAll(agents, store: store, workspace: workspace, check: authentication)
    }

    private func requireAuthentication(_ agent: AgentKind, workspace: Workspace? = nil) async throws {
        let status = await authentication(agent, store, workspace)
        try Task.checkCancellation()
        if status.requiresSignIn { throw AgentAuthenticationRequired(agent: agent) }
    }

    private func queue() -> ServerPromptQueue {
        if let promptQueue { return promptQueue }
        let queue = ServerPromptQueue(store: store, load: { [weak self] id in
            guard let self else { throw ServerFailure("The server is shutting down.") }
            return try await self.authenticatedSession(id)
        }, settled: { [weak self] id, ending in
            await self?.bridgeTurnEnded(sessionID: id, ending: ending)
        })
        promptQueue = queue
        return queue
    }

    func startBridge(socketPath: String) throws -> BridgeServer {
        let server = BridgeServer(store: store, socketPath: socketPath, toolbox: bridgeToolbox(),
            configurationDirectory: URL(fileURLWithPath: store.path).deletingLastPathComponent().appendingPathComponent("mcp-config").path)
        try server.start()
        bridge = server
        return server
    }

    public func restoreQueuedPrompts() async throws {
        // A deferred archive belongs to the interrupted turn, not whichever turn starts after
        // restarting this daemon. Require a fresh request instead of surprising a later caller.
        for workspace in try await store.workspaces() {
            for session in try await store.sessions(workspaceID: workspace.id) {
                let key = "server.archive.after-turn.\(session.id)"
                guard try await store.setting(key) != nil else { continue }
                try await store.setSetting(key, nil)
                let payload = try JSONEncoder().encode(JSONValue.object([
                    "message": .string("The pending archive request was cancelled because the server restarted before the turn ended. Review this workspace before requesting archive again."),
                ]))
                _ = try await store.appendNext(sessionID: session.id, kind: .error, payload: payload)
            }
        }
        try await queue().restore()
    }

    public func respond(to request: ServerRequest) async -> ServerReply {
        guard BloomWire.supportedVersions.contains(request.version) else {
            return ServerReply(id: request.id, result: .failure("Incompatible Bloom server protocol. Update the client and server."))
        }
        var reply = await dispatch(request)
        reply.version = request.version
        return reply
    }

    private func dispatch(_ request: ServerRequest) async -> ServerReply {
        if case .uiBridge = request.operation, request.version < 14 {
            return ServerReply(id: request.id, result: .failure("Workspace UI tools require Bloom protocol 14."))
        }
        if request.version < 13 {
            switch request.operation {
            case .storage, .cleanupStorage:
                return ServerReply(id: request.id, result: .failure("Storage management requires Bloom protocol 13 and the storageManagement capability."))
            default: break
            }
        }
        if case .diagnostics = request.operation, request.version < 13 {
            return ServerReply(id: request.id, result: .failure("Server diagnostics require Bloom protocol 13."))
        }
        guard !isClosed else { return ServerReply(id: request.id, result: .failure("The server is shutting down.")) }
        if case .uiBridge(let operation) = request.operation {
            do {
                if case .attach(let workspaceID, _, _) = operation { _ = try await workspace(workspaceID, readingDuringSetup: true) }
                return ServerReply(id: request.id, result: .uiBridge(try await uiBroker.handle(operation, registrationID: request.id)))
            } catch { return ServerReply(id: request.id, result: .failure(error.localizedDescription)) }
        }
        if !request.operation.mutates { return await execute(request) }
        if let task = commands[request.id] {
            _ = await task.value
            return await recorded(request)
        }
        // Register before awaiting the store. Concurrent retries share the same operation.
        let task = Task { await self.performOnce(request) }
        commands[request.id] = task
        commandOperations[request.id] = request.operation
        let reply = await task.value
        commands.removeValue(forKey: request.id)
        commandOperations.removeValue(forKey: request.id)
        return reply
    }

    private func key(_ request: ServerRequest) -> String { "server.command.\(request.id.uuidString)" }

    private func recorded(_ request: ServerRequest) async -> ServerReply {
        do {
            guard let value = try await store.setting(key(request)) else {
                throw ServerFailure("The command outcome is unknown. Refresh before trying again.")
            }
            let record = try JSONDecoder().decode(ServerCommandRecord.self, from: Data(value.utf8))
            guard record.request.id == request.id, record.request.operation == request.operation else { throw ServerFailure("A command ID cannot be reused for a different operation.") }
            return record.reply ?? ServerReply(id: request.id, result: .failure(
                "The server stopped while handling this command. Inspect the workspace before submitting a new command."
            ))
        } catch { return ServerReply(id: request.id, result: .failure(error.localizedDescription)) }
    }

    private func performOnce(_ request: ServerRequest) async -> ServerReply {
        do {
            if try await store.setting(key(request)) != nil { return await recorded(request) }
            try await saveRecord(ServerCommandRecord(request: request))
            let reply = await execute(request)
            try await saveRecord(ServerCommandRecord(request: request, reply: reply))
            return reply
        } catch { return ServerReply(id: request.id, result: .failure(error.localizedDescription)) }
    }

    private func saveRecord(_ record: ServerCommandRecord) async throws {
        let data = try JSONEncoder().encode(record)
        try await store.setSetting(key(record.request), String(decoding: data, as: UTF8.self))
    }

    private func execute(_ request: ServerRequest) async -> ServerReply {
        do {
            let permit: ServerWorkspaceAdmissions.Permit?
            switch request.operation.workspaceMutation {
            case .workspace(let id): permit = try workspaceAdmissions.admit(id)
            case .session(let id):
                guard let workspaceID = try await storedSession(id).workspaceID else { throw ServerFailure("This session has no workspace.") }
                permit = try workspaceAdmissions.admit(workspaceID)
            case nil: permit = nil
            }
            defer { permit?.release() }
            return ServerReply(id: request.id, result: try await execute(request.operation))
        } catch { return ServerReply(id: request.id, result: .failure(error.localizedDescription)) }
    }

    private func execute(_ operation: ServerOperation) async throws -> ServerResult {
        guard !isClosed else { throw ServerFailure("The server is shutting down.") }
        switch operation {
        case .uiBridge: throw ServerFailure("UI leases must be handled by the owning runtime.")
        case .creation(let action):
            var models: [CodexModel] = []
            if case .workspaceContext = action { models = (try? await modelCatalogue.pickerModels()) ?? [] }
            let repositoryDirectory = URL(fileURLWithPath: store.path).deletingLastPathComponent().appendingPathComponent("repositories").path
            var result = try await ProjectCreationOperations.perform(action, store: store, models: models,
                availableAgents: await installedAgents(store), defaultProjectLocation: repositoryDirectory)
            if case .workspaceContext(let id) = action, case .workspaceContext(var context) = result,
               let repo = try await store.repo(id: id) {
                let wrapped = !(SettingsLoader.load(workspace: repo.path, repo: repo.path).executionCommand ?? []).isEmpty
                if !wrapped { context.composer.authentication = await authenticationStatuses(context.composer.availableAgents ?? []) }
                result = .workspaceContext(context)
            }
            return .creation(result)
        case .reviewSnapshot(let id, let scope, let revision, let wait):
            return .reviewSnapshot(try await reviewCache.snapshot(workspace: workspace(id, readingDuringSetup: true), scope: scope, knownRevision: revision, wait: wait))
        case .reviewPatch(let id, let path, let scope, let revision):
            return .reviewPatch(try await reviewCache.patch(workspace: workspace(id, readingDuringSetup: true), path: path, scope: scope, knownRevision: revision))
        case .storage:
            return .storage(await storage.inspect())
        case .cleanupStorage(let targets):
            return .storageCleanup(try await storage.clean(targets))
        case .diagnostics:
            return .diagnostics(await ServerDiagnosticsCollector.collect(directory: (store.path as NSString).deletingLastPathComponent,
                authentication: await authenticationStatuses(await installedAgents(store))))
        case .hello:
            return .hello(name: ProcessInfo.processInfo.hostName)
        case .previewAddress(let address):
            return .text(try await ServerPreview.resolve(address))
        case .terminalStream(let id, let name):
            let workspace = try await workspace(id)
            let result = try await ServerWorkspaceOperations.perform(.terminal(name: name), workspace: workspace, store: store, terminals: terminals)
            guard case .terminal(let terminal) = result else { throw ServerFailure("The terminal could not be started.") }
            return .text(try await terminalStreams.open(terminal: terminal, workspace: workspace))
        case .composer(let id):
            let session = try await storedSession(id)
            guard let workspaceID = session.workspaceID else { throw ServerFailure("This session has no workspace.") }
            let path = try await workspace(workspaceID, readingDuringSetup: true).path
            let controls = try await ServerComposer.controls(session: session, store: store)
            let models = (try? await modelCatalogue.pickerModels()) ?? []
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return .composer(ServerComposerState(controls: controls, models: models,
                commands: SlashCommandIndex.discover(home: home, project: path),
                styles: OutputStyleIndex.discover(home: home, project: path), availableAgents: await installedAgents(store),
                authentication: await authenticationStatuses([controls.agentKind], workspace: try await workspace(workspaceID, readingDuringSetup: true))))
        case .markRead(let id, let seq):
            _ = try await storedSession(id)
            try await store.updateLastReadSeq(sessionID: id, seq: seq)
            return .accepted
        case .renameSession(let id, let title):
            _ = try await storedSession(id)
            let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.utf8.count <= 1_024 else { throw ServerFailure("Enter a shorter conversation name.") }
            try await store.updateSessionPreferences(id: id, title: name)
            return .accepted
        case .closeSession(let id):
            return try await closeSession(id, notifyingParent: true)
        case .setComposer(let id, let controls):
            try ServerAgentAvailability.require(controls.agentKind, in: await installedAgents(store))
            let session = try await storedSession(id)
            guard controls.agentKind.canRunWorkspaces, !controls.model.isEmpty else { throw ServerFailure("Choose an available agent and model.") }
            if controls.agentKind != session.agentKind {
                guard let workspaceID = session.workspaceID else { throw ServerFailure("This session has no workspace.") }
                let workspace = try await workspace(workspaceID)
                let result = try await ServerWorkspaceOperations.perform(.newSession(agent: controls.agentKind, model: controls.model,
                    effort: controls.effort, permissionMode: controls.permissionMode), workspace: workspace, store: store, terminals: terminals)
                if case .created(let created, _, _) = result { try await ServerComposer.save(controls, session: created, store: store) }
                return result
            }
            try await configure(id, controls: controls)
            return .accepted
        case .project(let id, let action):
            return try await ServerSidebar.project(action, id: id, store: store)
        case .catalogue:
            let workspaces = try await store.workspaces()
            var storedSessions: [Session] = []
            for workspace in workspaces { storedSessions += try await store.sessions(workspaceID: workspace.id) }
            return .catalogue(ServerCatalogue(
                repositories: try await store.repos(), workspaces: workspaces, sessions: storedSessions,
                archivedWorkspaces: try await store.workspaces(includeArchived: true).filter { $0.state == .archived }
            ))
        case .create(let request):
            return try await startWorkspace(request)
        case .transcript(let id, let afterSeq):
            guard afterSeq >= -1 else { throw ServerFailure("Invalid transcript cursor.") }
            let session = try await storedSession(id)
            let live = sessions[id]
            try await live?.refreshState(store: store, sessionID: id)
            let queued = try await queue().snapshot(id)
            return .transcript(ServerTranscript(
                session: session,
                messages: try await store.messages(sessionID: id, afterSeq: afterSeq, limit: 500),
                pendingQuestions: try await store.pendingPermissionAsks(sessionID: id).map { $0.ask.raw },
                isBusy: await live?.isBusy ?? false,
                streamingText: await live?.streamingText ?? "",
                permissionDecisions: try await store.permissionAskDecisions(sessionID: id),
                queuedPrompts: queued.0, queueError: queued.1
            ))
        case .workspace(let id, let action):
            switch action {
            case .archivePreview:
                return .archivePreview(try await prepareArchive(workspace(id)))
            case .archive(let confirmation): return try await archiveWorkspace(id, confirmation: confirmation)
            case .restore: return try await restoreWorkspace(id)
            case .newSession(let agent, _, _, _):
                try ServerAgentAvailability.require(agent, in: await installedAgents(store))
                return try await ServerWorkspaceOperations.perform(action, workspace: workspace(id), store: store, terminals: terminals)
            case .runSetup:
                let selected = try await workspace(id)
                guard changingWorkspaces.insert(id).inserted else { throw ServerFailure("This workspace is already being changed.") }
                settingUpWorkspaces.insert(id)
                defer {
                    changingWorkspaces.remove(id)
                    settingUpWorkspaces.remove(id)
                }
                let chats = try await store.sessions(workspaceID: id)
                for chat in chats {
                    let pending = try await store.pendingDeliveries(sessionID: chat.id)
                    let busy = await sessions[chat.id]?.isBusy == true
                    guard pending.isEmpty, !busy, creating[chat.id] == nil,
                          chat.state != .running, chat.state != .waiting else {
                        throw ServerFailure("Stop the workspace's agents and clear queued prompts before running setup again.")
                    }
                }
                return try await ServerWorkspaceOperations.perform(action, workspace: selected, store: store, terminals: terminals)
            default:
                return try await ServerWorkspaceOperations.perform(action,
                    workspace: workspace(id, readingDuringSetup: !action.mutates), store: store, terminals: terminals)
            }
        case .configure(let id, let model, let effort, let permissionMode):
            var controls = try await ServerComposer.controls(session: storedSession(id), store: store)
            controls.model = model
            controls.effort = effort
            controls.permissionMode = permissionMode
            try await configure(id, controls: controls)
            return .accepted
        case .send(let id, let text, let retryDeliveryID):
            guard stopping[id] == nil else { throw ServerFailure("This session is being stopped.") }
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty, body.utf8.count <= 1_048_576 else { throw ServerFailure("The prompt is empty or too large.") }
            let session = try await storedSession(id)
            try ServerAgentAvailability.require(session.agentKind, in: await installedAgents(store))
            guard session.archivedAt == nil else { throw ServerFailure("This conversation is closed.") }
            guard let workspaceID = session.workspaceID else { throw ServerFailure("This session has no workspace.") }
            let selected = try await workspace(workspaceID)
            try await requireAuthentication(session.agentKind, workspace: selected)
            if let retryDeliveryID {
                try await queue().retryAuthenticationPaused(sessionID: id, deliveryID: retryDeliveryID, text: body)
            } else { try await queue().enqueue(body, sessionID: id) }
            return .accepted
        case .cancelQueued(let id, let deliveryID):
            try await queue().cancel(deliveryID, sessionID: id)
            return .accepted
        case .changes(let id, let scope):
            return .changes(try await ServerReview.changes(workspace: workspace(id, readingDuringSetup: true), scope: scope))
        case .patch(let id, let path, let scope):
            return .patch(try await ServerReview.patch(workspace: workspace(id, readingDuringSetup: true), path: path, scope: scope))
        case .file(let id, let path):
            let selected = try await workspace(id, readingDuringSetup: true)
            return .file(try ServerReview.file(workspace: selected, path: path))
        case .stop(let id):
            stopping[id, default: 0] += 1
            defer {
                stopping[id, default: 1] -= 1
                if stopping[id] == 0 { stopping.removeValue(forKey: id) }
            }
            // A Stop received during runner creation must also stop that pending start. Wait
            // for already accepted sends to settle while refusing new ones for this session.
            let sends = commandOperations.compactMap { commandID, operation -> Task<ServerReply, Never>? in
                if case .send(let target, _, _) = operation, target == id { return commands[commandID] }
                return nil
            }
            for send in sends { _ = await send.value }
            _ = try await storedSession(id)
            try await queue().pause(id)
            await sessions[id]?.stop()
            return .accepted
        case .answer(let id, let requestID, let answer):
            guard let live = sessions[id] else { throw ServerFailure("This session has no running agent.") }
            if case .denyWithReason(_, let endsTurn) = answer, endsTurn { try await queue().pause(id) }
            try await live.answer(requestID: requestID, decision: answer.decision, store: store, sessionID: id)
            return .accepted
        }
    }

    private func closeSession(_ id: SessionID, notifyingParent: Bool) async throws -> ServerResult {
        guard closingSessions.insert(id).inserted else { throw ServerFailure("This conversation is already being closed.") }
        defer { closingSessions.remove(id) }
        let session = try await storedSession(id)
        guard session.archivedAt == nil else { return .accepted }
        stopping[id, default: 0] += 1
        defer {
            stopping[id, default: 1] -= 1
            if stopping[id] == 0 { stopping.removeValue(forKey: id) }
        }
        _ = try await execute(.stop(sessionID: id))
        if notifyingParent, let parentID = session.parentSessionID, let workspaceID = session.workspaceID,
           let parent = try await store.session(id: parentID), parent.archivedAt == nil, parent.workspaceID == workspaceID {
            try? await queue().enqueue(Delivery(targetSessionID: parentID, sourceWorkspaceID: workspaceID, kind: .report,
                                               crew: .stoppedByOwner(name: session.title)))
        }
        await sessions[id]?.shutdown()
        sessions.removeValue(forKey: id)
        bridge?.retire(sessionID: id)
        _ = try await store.update(sessionID: id) { $0.archivedAt = Date() }
        return .accepted
    }

    private func storedSession(_ id: SessionID) async throws -> Session {
        guard let session = try await store.session(id: id) else { throw ServerFailure("This session no longer exists.") }
        return session
    }

    private func configure(_ id: SessionID, controls: ComposerControls) async throws {
        guard !controls.model.isEmpty else { throw ServerFailure("Choose a model.") }
        guard stopping[id] == nil else { throw ServerFailure("This session is being changed. Try again shortly.") }
        stopping[id] = 1
        defer { stopping.removeValue(forKey: id) }
        for (commandID, operation) in commandOperations {
            if case .send(let target, _, _) = operation, target == id { _ = await commands[commandID]?.value }
        }
        let queued = try await queue().snapshot(id)
        guard queued.0.isEmpty else { throw ServerFailure("Wait for queued messages before changing settings.") }
        if let live = sessions[id] {
            try await live.refreshState(store: store, sessionID: id)
            guard await !live.isBusy else { throw ServerFailure("Stop the current turn before changing its settings.") }
            await live.shutdown()
            sessions.removeValue(forKey: id)
        }
        let session = try await storedSession(id)
        try await ServerComposer.save(controls, session: session, store: store)
    }

    private func workspace(_ id: WorkspaceID, readingDuringSetup: Bool = false) async throws -> Workspace {
        guard !changingWorkspaces.contains(id) || (readingDuringSetup && settingUpWorkspaces.contains(id)) else { throw ServerFailure("This workspace is being set up, archived or restored. Try again shortly.") }
        guard let workspace = try await store.workspace(id: id), workspace.state == .active else {
            throw ServerFailure("This workspace is no longer available.")
        }
        return workspace
    }

    private func prepareArchive(_ workspace: Workspace, keepingBranch: Bool = false) async throws -> ServerArchivePreview {
        var preview = try await ServerSidebar.preview(workspace: workspace, store: store)
        if keepingBranch { preview.hazards.isDeletingBranch = false }
        archivePreviews = archivePreviews.filter { Date().timeIntervalSince($0.value.createdAt) < 600 }
        archivePreviews[preview.id] = preview
        return preview
    }

    private func archiveWorkspace(_ id: WorkspaceID, confirmation: UUID, bridgeSafe: Bool = false) async throws -> ServerResult {
        guard changingWorkspaces.insert(id).inserted else { throw ServerFailure("This workspace is already being changed.") }
        defer { changingWorkspaces.remove(id) }
        let transition = try workspaceAdmissions.beginTransition(id)
        var remainsClosed = false
        defer { transition.finish(closed: remainsClosed) }
        guard let workspace = try await store.workspace(id: id) else { throw ServerFailure("This workspace no longer exists.") }
        if workspace.state == .archived { remainsClosed = true; return .accepted }
        guard let accepted = archivePreviews[confirmation], accepted.workspace.id == id,
              Date().timeIntervalSince(accepted.createdAt) < 600 else {
            return .archivePreview(try await prepareArchive(workspace, keepingBranch: bridgeSafe))
        }
        // Both RPC and MCP mutations hold tickets, including work paused before its first
        // Store write. Capture sessions only once those accepted operations have settled.
        try await transition.drain()
        let fresh = try await prepareArchive(workspace, keepingBranch: bridgeSafe)
        guard fresh.report == accepted.report, fresh.hazards == accepted.hazards else { return .archivePreview(fresh) }
        let chats = try await store.sessions(workspaceID: id)
        for chat in chats {
            _ = try await execute(.stop(sessionID: chat.id))
            if let pending = creating[chat.id] { _ = try? await pending.value }
            await sessions[chat.id]?.shutdown()
            sessions.removeValue(forKey: chat.id)
            bridge?.retire(sessionID: chat.id)
        }
        let settled = try await prepareArchive(workspace, keepingBranch: bridgeSafe)
        guard settled.report == accepted.report, settled.hazards.isDeletingBranch == accepted.hazards.isDeletingBranch else {
            return .archivePreview(settled)
        }
        guard let repo = try await store.repo(id: workspace.repoID) else { throw ServerFailure("This project's repository is unavailable.") }
        try await WorkspaceManager(store: store).archive(workspace: workspace, repo: repo,
            deleteBranch: accepted.hazards.isDeletingBranch, force: !bridgeSafe)
        remainsClosed = true
        await uiBroker.close(workspaceID: id)
        await terminalStreams.close(workspaceID: id)
        try await terminals.close(workspaceID: id, store: store, cwd: repo.path)
        archivePreviews = archivePreviews.filter { $0.value.workspace.id != id }
        return .accepted
    }

    private func restoreWorkspace(_ id: WorkspaceID) async throws -> ServerResult {
        guard !changingWorkspaces.contains(id) else { throw ServerFailure("This workspace is already being changed.") }
        changingWorkspaces.insert(id)
        defer { changingWorkspaces.remove(id) }
        let transition = try workspaceAdmissions.beginTransition(id)
        var remainsClosed = false
        defer { transition.finish(closed: remainsClosed) }
        try await transition.drain()
        guard let workspace = try await store.workspace(id: id), let repo = try await store.repo(id: workspace.repoID) else {
            throw ServerFailure("This workspace's project is unavailable.")
        }
        if workspace.state == .active { return .accepted }
        remainsClosed = true
        _ = try await WorkspaceManager(store: store).restore(workspace: workspace, repo: repo)
        remainsClosed = false
        return .accepted
    }

    private func startWorkspace(_ request: ServerWorkspaceRequest, origin: WorkspaceOrigin = .user) async throws -> ServerResult {
        let controls = request.controls ?? ComposerControls(model: request.model, effort: request.effort,
            agentKind: request.agent, permissionMode: request.permissionMode)
        let mode = request.mode ?? .chat
        guard controls.agentKind.canRunWorkspaces, !controls.model.isEmpty, !request.repositoryPath.isEmpty,
              !mode.runsAnAgent || !(request.prompt ?? request.name).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ServerFailure("Choose a project, a model and a task for the workspace.")
        }
        if mode.runsAnAgent {
            try ServerAgentAvailability.require(controls.agentKind, in: await installedAgents(store))
            let wrapped = !(SettingsLoader.load(workspace: request.repositoryPath, repo: request.repositoryPath).executionCommand ?? []).isEmpty
            let currentBranch = try? await Git.currentBranch(of: request.repositoryPath)
            let branchMatches = request.baseBranch == nil || request.baseBranch == currentBranch
            if !wrapped, request.checkout == nil, branchMatches { try await requireAuthentication(controls.agentKind) }
        }
        let attachments = request.attachments ?? []
        guard attachments.reduce(0, { $0 + $1.data.count }) <= 10_000_000 else { throw ServerFailure("Use up to 10 MB of attachments in the first message.") }
        guard Set(attachments.map(\.sourcePath)).count == attachments.count else { throw ServerFailure("Attach each file once.") }
        for attachment in attachments {
            guard attachment.sourcePath.hasPrefix(".bloom/attachments/"), !attachment.sourcePath.contains("..") else { throw ServerFailure("Invalid staged attachment path.") }
            try ServerFileOperations.validateUpload(name: attachment.name, data: attachment.data)
        }
        let manager = WorkspaceManager(store: store)
        let path = try await repositories.resolve(request.repositoryPath, dataDirectory: URL(fileURLWithPath: store.path).deletingLastPathComponent())
        let repo = try await manager.addRepository(at: path)
        let started = try await manager.start(WorkspaceStartRequest(
            repo: repo, prompt: request.prompt ?? request.name, origin: origin, baseBranch: request.baseBranch,
            name: request.mode == nil ? request.name : nil, checkout: request.checkout, controls: controls,
            opensSession: mode.runsAnAgent, setupPolicy: request.runSetupScript == false ? .skip : .run
        ))
        var prompt = request.prompt ?? ""
        for attachment in attachments {
            let uploaded = try ServerFileOperations.upload(workspace: started.workspace, name: attachment.name, data: attachment.data)
            prompt = prompt.replacingOccurrences(of: attachment.sourcePath, with: uploaded)
        }
        var keptDraft = started.setupSucceeded == false ? prompt : nil
        if let session = started.session {
            try await ServerComposer.save(controls, session: session, store: store)
            if !prompt.isEmpty, started.setupSucceeded != false {
                let status = await authentication(controls.agentKind, store, started.workspace)
                if status.requiresSignIn, request.mode != nil {
                    keptDraft = prompt
                    try await store.saveDraft(sessionID: session.id, body: prompt)
                } else { try await queue().enqueue(prompt, sessionID: session.id) }
            }
        }
        if request.mode != nil {
            return .creation(.workspaceStarted(workspace: started.workspace, session: started.session,
                setupSucceeded: started.setupSucceeded, draft: keptDraft))
        }
        guard let session = started.session else { throw ServerFailure("The workspace has no session.") }
        return .created(session: session, workspace: started.workspace, setupSucceeded: started.setupSucceeded)
    }

    private func authenticatedSession(_ id: SessionID) async throws -> ServerSession {
        if await sessions[id]?.isBusy != true {
            let session = try await storedSession(id)
            guard let workspaceID = session.workspaceID else { throw ServerFailure("This session has no workspace.") }
            try await requireAuthentication(session.agentKind, workspace: workspace(workspaceID))
        }
        return try await liveSession(id)
    }

    private func liveSession(_ id: SessionID) async throws -> ServerSession {
        guard !isClosed, !closingSessions.contains(id), try await storedSession(id).archivedAt == nil else {
            throw ServerFailure("This conversation is closed. Open a new chat before sending a message.")
        }
        if !changingWorkspaces.isEmpty {
            let stored = try await storedSession(id)
            if let workspaceID = stored.workspaceID, changingWorkspaces.contains(workspaceID) {
                throw ServerFailure("This workspace is being set up, archived or restored.")
            }
        }
        if let session = sessions[id] { return session }
        if let task = creating[id] {
            let live = try await task.value
            guard !isClosed else {
                await live.shutdown()
                throw ServerFailure("The server is shutting down.")
            }
            return live
        }
        let task = Task { () throws -> ServerSession in
            let session = try await self.storedSession(id)
            guard session.archivedAt == nil else { throw ServerFailure("This conversation is closed.") }
            guard let workspaceID = session.workspaceID,
                  let workspace = try await self.store.workspace(id: workspaceID), workspace.state == .active else {
                throw ServerFailure("This workspace is no longer available.")
            }
            let handle = self.bridge?.register(session: session, workspace: workspace)
            let runner = self.makeRunner?(session, workspace.path, self.store)
                ?? SessionRunnerFactory.make(session: session, workspacePath: workspace.path, store: self.store, bridge: handle)
            return ServerSession(runner: runner) { [weak self] ending in await self?.queue().turnEnded(session.id, ending: ending) }
        }
        creating[id] = task
        do {
            let live = try await task.value
            creating.removeValue(forKey: id)
            guard !isClosed else {
                await live.shutdown()
                throw ServerFailure("The server is shutting down.")
            }
            sessions[id] = live
            return live
        } catch {
            creating.removeValue(forKey: id)
            throw error
        }
    }

    public func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        isClosed = true
        workspaceAdmissions.stop()
        let task = Task { await self.finishShutdown() }
        shutdownTask = task
        await task.value
    }

    private func finishShutdown() async {
        let runningCommands = Array(commands.values)
        for command in runningCommands { command.cancel() }
        let archiving = Array(bridgeArchives.values)
        for task in archiving { task.cancel() }
        await uiBroker.shutdown()
        await bridge?.shutdown()
        await reviewCache.shutdown()
        await promptQueue?.shutdown()
        await terminalStreams.shutdown()
        await terminals.shutdown()
        let liveSessions = Array(sessions.values)
        await withTaskGroup(of: Void.self) { group in
            for session in liveSessions { group.addTask { await session.shutdown() } }
        }
        for command in runningCommands { _ = await command.value }
        for task in archiving { await task.value }
        await workspaceAdmissions.waitUntilIdle()
        sessions.removeAll()
    }
}

extension ServerRuntime {
    private func bridgeToolbox() -> BridgeToolbox {
        BridgeToolbox(handlers: BridgeToolbox.standard.handlers + ServerUIBridgeTools.handlers(broker: uiBroker, store: store) + [
            WorkspaceStartTool { [weak self] order, project, identity, origin in
                guard let self else { throw ServerFailure("The server is shutting down.") }
                return try await self.startWorkspaceForBridge(order, project: project, identity: identity, origin: origin)
            },
            AgentStartTool { [weak self] order, sessionID, workspaceID in
                guard let self else { return .refused("The server is shutting down.") }
                return await self.startCrewForBridge(order, sessionID: sessionID, workspaceID: workspaceID)
            },
            AgentSayTool { [weak self] name, text, sessionID, workspaceID in
                guard let self else { return .refused("The server is shutting down.") }
                return await self.sayForBridge(name, text: text, sessionID: sessionID, workspaceID: workspaceID)
            },
            AgentStopTool { [weak self] name, sessionID, workspaceID in
                guard let self else { return .refused("The server is shutting down.") }
                return await self.stopCrewForBridge(name, sessionID: sessionID, workspaceID: workspaceID)
            },
            WorkspaceArchiveTool { [weak self] order in
                guard let self else { return .refused("The server is shutting down.") }
                return await self.archiveForBridge(order)
            },
            WorkspaceMergeTool { [weak self] workspace, pullRequest, method in
                guard let self else { return .refused("The server is shutting down.") }
                return await self.mergeForBridge(workspace, pullRequest: pullRequest, method: method)
            },
        ])
    }
}

extension ServerRuntime {
    private func startWorkspaceForBridge(_ order: AgentWorkspaceOrder, project: Repo, identity: BridgeIdentity, origin: WorkspaceOrigin) async throws -> StartedWorkspaceSummary {
        var inherited = ComposerControls()
        if let id = identity.sessionID, let session = try await store.session(id: id) {
            inherited = try await ServerComposer.controls(session: session, store: store)
        }
        let controls = try await BridgeWorkspaceControls.resolve(for: order, inheriting: inherited)
        var request = ServerWorkspaceRequest(repositoryPath: project.path, name: order.name ?? order.prompt)
        request.prompt = order.prompt; request.controls = controls
        request.baseBranch = order.source.baseBranch; request.checkout = order.source.checkout
        let result = try await startWorkspace(request, origin: origin)
        guard case .created(_, let workspace, _) = result else { throw ServerFailure("The server did not return the new workspace.") }
        return StartedWorkspaceSummary(workspaceID: workspace.id, name: workspace.name, branch: workspace.branch, path: workspace.path)
    }
}

extension ServerRuntime {
    private func startCrewForBridge(_ order: CrewOrder, sessionID: SessionID, workspaceID: WorkspaceID) async -> CrewStartOutcome {
        do {
            let permit = try workspaceAdmissions.admit(workspaceID)
            defer { permit.release() }
            guard !isClosed, !closingSessions.contains(sessionID) else { throw Crew.StartRefusal.parentUnavailable }
            _ = try await workspace(workspaceID)
            let available = await installedAgents(store)
            let member = try await store.startCrewMember(order, parentID: sessionID, workspaceID: workspaceID, availableAgents: available)
            try await queue().resumeStoredDeliveries(member.id)
            return .started("Started subagent '\(member.title)' in this workspace. Talk to it with agent_say; its final response will return here when it stops.")
        } catch let refusal as Crew.StartRefusal {
            return .refused(Crew.sentence(for: refusal))
        } catch { return .refused(error.localizedDescription) }
    }

    private func sayForBridge(_ name: String?, text: String, sessionID: SessionID, workspaceID: WorkspaceID) async -> CrewSayOutcome {
        do {
            let permit = try workspaceAdmissions.admit(workspaceID)
            defer { permit.release() }
            let caller = try await storedSession(sessionID)
            guard caller.workspaceID == workspaceID else { throw ServerFailure("The calling chat belongs to another workspace.") }
            _ = try await workspace(workspaceID)
            let target: Session
            let message: CrewMessage
            if let name {
                let members = try await store.crew(of: sessionID)
                guard case .found(let member) = CrewLookup.find(name, among: members) else {
                    throw ServerFailure("That subagent name is missing or ambiguous. Call agent_list again.")
                }
                target = member; message = .said(from: caller.title, text: text, sender: .orchestrator)
            } else {
                guard let parentID = caller.parentSessionID else { throw ServerFailure("This chat has no parent agent. Name a subagent to message.") }
                target = try await storedSession(parentID)
                guard target.workspaceID == workspaceID else { throw ServerFailure("The parent chat belongs to another workspace.") }
                message = .said(from: caller.title, text: text, sender: .subagent)
            }
            guard target.archivedAt == nil else { throw ServerFailure("That conversation is closed. Start a new subagent instead.") }
            try await queue().enqueue(Delivery(targetSessionID: target.id, sourceWorkspaceID: workspaceID, kind: .message, crew: message))
            return .delivered("Queued that for '\(target.title)'. Messages arrive in order; a busy agent reads this after its current turn ends.")
        } catch { return .refused(error.localizedDescription) }
    }

    private func stopCrewForBridge(_ name: String, sessionID: SessionID, workspaceID: WorkspaceID) async -> CrewStopOutcome {
        do {
            let permit = try workspaceAdmissions.admit(workspaceID)
            defer { permit.release() }
            let caller = try await storedSession(sessionID)
            guard caller.workspaceID == workspaceID else { throw ServerFailure("The calling chat belongs to another workspace.") }
            let members = try await store.crew(of: sessionID)
            guard case .found(let member) = CrewLookup.find(name, among: members) else {
                throw ServerFailure("That subagent name is missing or ambiguous. Call agent_list again.")
            }
            _ = try await closeSession(member.id, notifyingParent: false)
            return .stopped("Stopped subagent '\(member.title)' and closed its chat. Its conversation was kept.")
        } catch { return .refused(error.localizedDescription) }
    }

    private func archiveForBridge(_ order: WorkspaceArchiveOrder) async -> WorkspaceArchiveOutcome {
        do {
            let current = try await workspace(order.workspace.id)
            if let sessionID = order.afterTurnOf {
                let permit = try workspaceAdmissions.admit(current.id)
                defer { permit.release() }
                let caller = try await storedSession(sessionID)
                guard caller.workspaceID == current.id else { throw ServerFailure("The calling chat belongs to another workspace.") }
                try await store.setSetting("server.archive.after-turn.\(sessionID)", current.id.rawValue)
                return .requested
            }
            if let objection = await WorkspaceArchiveSafety.objection(to: current, excusing: nil, store: store) { return .refused(objection) }
            let preview = try await prepareArchive(current, keepingBranch: true)
            guard preview.report.isSafeToDiscard(deletingBranch: false, isPullRequestMerged: preview.hazards.isPullRequestMerged),
                  !preview.hazards.isAgentRunning else {
                return .refused("Archiving needs confirmation because this workspace has unprotected work. Review its archive preview in Bloom.")
            }
            let result = try await archiveWorkspace(current.id, confirmation: preview.id, bridgeSafe: true)
            guard case .accepted = result else { return .refused("The workspace changed while it was being checked. Review its archive preview again.") }
            return .archived
        } catch { return .refused(error.localizedDescription) }
    }

    private func mergeForBridge(_ target: Workspace, pullRequest: PullRequest, method: GitHub.MergeMethod) async -> WorkspaceMergeHandoff {
        do {
            let permit = try workspaceAdmissions.admit(target.id)
            defer { permit.release() }
            let workspace = try await workspace(target.id)
            guard let repo = try await store.repo(id: workspace.repoID) else { throw ServerFailure("This workspace's project is unavailable.") }
            let existing = try await store.sessions(workspaceID: workspace.id)
            let session: Session
            if let current = existing.first(where: { $0.parentSessionID == nil }) { session = current } else {
                session = try await ServerWorkspaceOperations.createSession(workspace: workspace, controls: ComposerControls(), title: "Merge", store: store)
            }
            let template = try await store.setting(PromptOverrides.key(for: .mergePullRequest))
                ?? PromptRegistry.definition(for: .mergePullRequest).defaultTemplate
            let context = MergePromptContext(workspaceName: workspace.name, number: pullRequest.number, title: pullRequest.title,
                                             branch: pullRequest.branch, baseBranch: workspace.baseBranch, method: method)
            let settings = SettingsLoader.load(workspace: workspace.path, repo: repo.path)
            let extra = ProjectInstructions.resolve(.merge, in: workspace.path, stated: ProjectInstructions.stated(.merge, in: settings))
            let text = ProjectInstructions.turn(context.render(template: template).text, for: .merge, adding: extra)
            try await queue().enqueue(text, sessionID: session.id)
            return .turnBegun(chat: session.title)
        } catch { return .refused(error.localizedDescription) }
    }

    private func bridgeTurnEnded(sessionID: SessionID, ending: CrewTurnEnd) async {
        guard !isClosed, !closingSessions.contains(sessionID),
              let session = try? await store.session(id: sessionID), session.archivedAt == nil, let workspaceID = session.workspaceID else { return }
        if let parentID = session.parentSessionID, session.archivedAt == nil,
           let parent = try? await store.session(id: parentID), parent.archivedAt == nil,
           let report = ending.report(name: session.title, continuing: false) {
            try? await queue().enqueue(Delivery(targetSessionID: parentID, sourceWorkspaceID: workspaceID, kind: .report, crew: report))
        }
        guard (try? await store.setting("server.archive.after-turn.\(sessionID)")) != nil else { return }
        if case .cancelled = ending {
            try? await store.setSetting("server.archive.after-turn.\(sessionID)", nil)
            return
        }
        // The archive closes this runner. Run it outside that runner's event pump so closing the
        // pump cannot cancel the archive halfway through its normal lifecycle.
        bridgeArchives[sessionID]?.cancel()
        bridgeArchives[sessionID] = Task { [weak self] in await self?.completeBridgeArchive(sessionID: sessionID, workspaceID: workspaceID) }
    }

    private func completeBridgeArchive(sessionID: SessionID, workspaceID: WorkspaceID) async {
        defer { bridgeArchives[sessionID] = nil }
        try? await store.setSetting("server.archive.after-turn.\(sessionID)", nil)
        guard !isClosed, let workspace = try? await store.workspace(id: workspaceID) else { return }
        if case .refused(let reason) = await archiveForBridge(.init(workspace: workspace, afterTurnOf: nil)) {
            let payload = try? JSONEncoder().encode(JSONValue.object(["message": .string("The requested archive was not completed. " + reason)]))
            if let payload { _ = try? await store.appendNext(sessionID: sessionID, kind: .error, payload: payload) }
        }
    }
}
