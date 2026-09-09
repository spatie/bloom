import Foundation

/// The standalone runtime is the single owner of its store and its session runners. Clients
/// request snapshots and commands, never open its SQLite file or launch a second runner.
public actor ServerRuntime {
    public typealias RunnerFactory = @Sendable (Session, String, Store) -> any SessionRunner
    private let store: Store
    private let makeRunner: RunnerFactory
    private let repositories = ServerRepositoryResolver()
    private let terminals = ServerTerminalService()
    private let terminalStreams: ServerTerminalStreams
    private let modelCatalogue = CodexModelCatalog.live()
    private var sessions: [SessionID: ServerSession] = [:]
    private var creating: [SessionID: Task<ServerSession, Error>] = [:]
    private var commands: [UUID: Task<ServerReply, Never>] = [:]
    private var commandOperations: [UUID: ServerOperation] = [:]
    private var stopping: [SessionID: Int] = [:]
    private var changingWorkspaces: Set<WorkspaceID> = []
    private var archivePreviews: [UUID: ServerArchivePreview] = [:]
    private var isClosed = false
    private var promptQueue: ServerPromptQueue?

    public init(store: Store, gatewayGroupID: UInt32? = nil, makeRunner: @escaping RunnerFactory = { session, path, store in
        SessionRunnerFactory.make(session: session, workspacePath: path, store: store)
    }) {
        self.store = store
        terminalStreams = ServerTerminalStreams(groupID: gatewayGroupID)
        self.makeRunner = makeRunner
    }

    private func queue() -> ServerPromptQueue {
        if let promptQueue { return promptQueue }
        let queue = ServerPromptQueue(store: store) { [weak self] id in
            guard let self else { throw ServerFailure("The server is shutting down.") }
            return try await self.liveSession(id)
        }
        promptQueue = queue
        return queue
    }

    public func restoreQueuedPrompts() async throws { try await queue().restore() }

    public func respond(to request: ServerRequest) async -> ServerReply {
        guard request.version == ServerRequest.protocolVersion else {
            return ServerReply(id: request.id, result: .failure("Incompatible Bloom server protocol. Update the client and server."))
        }
        guard !isClosed else { return ServerReply(id: request.id, result: .failure("The server is shutting down.")) }
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
            guard record.request == request else { throw ServerFailure("A command ID cannot be reused for a different operation.") }
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
        do { return ServerReply(id: request.id, result: try await execute(request.operation)) } catch { return ServerReply(id: request.id, result: .failure(error.localizedDescription)) }
    }

    private func execute(_ operation: ServerOperation) async throws -> ServerResult {
        guard !isClosed else { throw ServerFailure("The server is shutting down.") }
        switch operation {
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
            let path = try await workspace(workspaceID).path
            let controls = try await ServerComposer.controls(session: session, store: store)
            let models = (try? await modelCatalogue.pickerModels()) ?? []
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return .composer(ServerComposerState(controls: controls, models: models,
                commands: SlashCommandIndex.discover(home: home, project: path),
                styles: OutputStyleIndex.discover(home: home, project: path)))
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
            stopping[id, default: 0] += 1
            defer {
                stopping[id, default: 1] -= 1
                if stopping[id] == 0 { stopping.removeValue(forKey: id) }
            }
            _ = try await execute(.stop(sessionID: id))
            await sessions[id]?.shutdown()
            sessions.removeValue(forKey: id)
            _ = try await store.update(sessionID: id) { $0.archivedAt = Date() }
            return .accepted
        case .setComposer(let id, let controls):
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
            try await ServerSidebar.project(action, id: id, store: store)
            return .accepted
        case .catalogue:
            let workspaces = try await store.workspaces()
            var storedSessions: [Session] = []
            for workspace in workspaces { storedSessions += try await store.sessions(workspaceID: workspace.id) }
            return .catalogue(ServerCatalogue(
                repositories: try await store.repos(), workspaces: workspaces, sessions: storedSessions,
                archivedWorkspaces: try await store.workspaces(includeArchived: true).filter { $0.state == .archived }
            ))
        case .create(let request):
            guard request.agent.canRunWorkspaces else { throw ServerFailure("This agent backend is not supported.") }
            guard !request.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !request.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !request.repositoryPath.isEmpty else {
                throw ServerFailure("Enter a workspace name, model and repository path or Git URL.")
            }
            let manager = WorkspaceManager(store: store)
            let path = try await repositories.resolve(request.repositoryPath, dataDirectory: URL(fileURLWithPath: store.path).deletingLastPathComponent())
            let repo = try await manager.addRepository(at: path)
            let started = try await manager.start(WorkspaceStartRequest(
                repo: repo, prompt: request.name, origin: .user, name: request.name,
                controls: ComposerControls(
                    model: request.model, effort: request.effort, agentKind: request.agent,
                    permissionMode: request.permissionMode
                ), setupPolicy: .run
            ))
            guard let session = started.session else { throw ServerFailure("The workspace has no session.") }
            return .created(session: session, workspace: started.workspace, setupSucceeded: started.setupSucceeded)
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
            case .runSetup:
                let selected = try await workspace(id)
                changingWorkspaces.insert(id)
                defer { changingWorkspaces.remove(id) }
                return try await ServerWorkspaceOperations.perform(action, workspace: selected, store: store, terminals: terminals)
            default:
                return try await ServerWorkspaceOperations.perform(action, workspace: workspace(id), store: store, terminals: terminals)
            }
        case .configure(let id, let model, let effort, let permissionMode):
            var controls = try await ServerComposer.controls(session: storedSession(id), store: store)
            controls.model = model
            controls.effort = effort
            controls.permissionMode = permissionMode
            try await configure(id, controls: controls)
            return .accepted
        case .send(let id, let text):
            guard stopping[id] == nil else { throw ServerFailure("This session is being stopped.") }
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty, body.utf8.count <= 1_048_576 else { throw ServerFailure("The prompt is empty or too large.") }
            let session = try await storedSession(id)
            guard session.archivedAt == nil else { throw ServerFailure("This conversation is closed.") }
            guard let workspaceID = session.workspaceID else { throw ServerFailure("This session has no workspace.") }
            _ = try await workspace(workspaceID)
            try await queue().enqueue(body, sessionID: id)
            return .accepted
        case .cancelQueued(let id, let deliveryID):
            try await queue().cancel(deliveryID, sessionID: id)
            return .accepted
        case .changes(let id, let scope):
            return .changes(try await ServerReview.changes(workspace: workspace(id), scope: scope))
        case .patch(let id, let path, let scope):
            return .patch(try await ServerReview.patch(workspace: workspace(id), path: path, scope: scope))
        case .file(let id, let path):
            let selected = try await workspace(id)
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
                if case .send(let target, _) = operation, target == id { return commands[commandID] }
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
            if case .send(let target, _) = operation, target == id { _ = await commands[commandID]?.value }
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

    private func workspace(_ id: WorkspaceID) async throws -> Workspace {
        guard !changingWorkspaces.contains(id) else { throw ServerFailure("This workspace is being archived or restored. Try again shortly.") }
        guard let workspace = try await store.workspace(id: id), workspace.state == .active else {
            throw ServerFailure("This workspace is no longer available.")
        }
        return workspace
    }

    private func prepareArchive(_ workspace: Workspace) async throws -> ServerArchivePreview {
        let preview = try await ServerSidebar.preview(workspace: workspace, store: store)
        archivePreviews = archivePreviews.filter { Date().timeIntervalSince($0.value.createdAt) < 600 }
        archivePreviews[preview.id] = preview
        return preview
    }

    private func archiveWorkspace(_ id: WorkspaceID, confirmation: UUID) async throws -> ServerResult {
        guard changingWorkspaces.insert(id).inserted else { throw ServerFailure("This workspace is already being changed.") }
        defer { changingWorkspaces.remove(id) }
        guard let workspace = try await store.workspace(id: id) else { throw ServerFailure("This workspace no longer exists.") }
        if workspace.state == .archived { return .accepted }
        guard let accepted = archivePreviews[confirmation], accepted.workspace.id == id,
              Date().timeIntervalSince(accepted.createdAt) < 600 else {
            return .archivePreview(try await prepareArchive(workspace))
        }
        let sessionIDs = Set(try await store.sessions(workspaceID: id).map(\.id))
        // Finish commands already accepted before checking what the confirmation covers.
        let pending = commandOperations.compactMap { key, operation -> Task<ServerReply, Never>? in
            if case .workspace(let target, let action) = operation, target == id, action.mutates {
                if case .archive = action { return nil }
                if case .restore = action { return nil }
                return commands[key]
            }
            switch operation {
            case .terminalStream(let target, _): return target == id ? commands[key] : nil
            case .send(let target, _), .setComposer(let target, _), .configure(let target, _, _, _),
                 .closeSession(let target), .stop(let target), .answer(let target, _, _):
                return sessionIDs.contains(target) ? commands[key] : nil
            default: return nil
            }
        }
        for task in pending { _ = await task.value }
        let fresh = try await prepareArchive(workspace)
        guard fresh.report == accepted.report, fresh.hazards == accepted.hazards else { return .archivePreview(fresh) }
        let chats = try await store.sessions(workspaceID: id)
        for chat in chats {
            _ = try await execute(.stop(sessionID: chat.id))
            if let pending = creating[chat.id] { _ = try? await pending.value }
            await sessions[chat.id]?.shutdown()
            sessions.removeValue(forKey: chat.id)
        }
        let settled = try await prepareArchive(workspace)
        guard settled.report == accepted.report, settled.hazards.isDeletingBranch == accepted.hazards.isDeletingBranch else {
            return .archivePreview(settled)
        }
        guard let repo = try await store.repo(id: workspace.repoID) else { throw ServerFailure("This project's repository is unavailable.") }
        try await WorkspaceManager(store: store).archive(workspace: workspace, repo: repo,
            deleteBranch: accepted.hazards.isDeletingBranch, force: true)
        await terminalStreams.close(workspaceID: id)
        try await terminals.close(workspaceID: id, store: store, cwd: repo.path)
        archivePreviews = archivePreviews.filter { $0.value.workspace.id != id }
        return .accepted
    }

    private func restoreWorkspace(_ id: WorkspaceID) async throws -> ServerResult {
        guard !changingWorkspaces.contains(id) else { throw ServerFailure("This workspace is already being changed.") }
        changingWorkspaces.insert(id)
        defer { changingWorkspaces.remove(id) }
        guard let workspace = try await store.workspace(id: id), let repo = try await store.repo(id: workspace.repoID) else {
            throw ServerFailure("This workspace's project is unavailable.")
        }
        if workspace.state == .active { return .accepted }
        _ = try await WorkspaceManager(store: store).restore(workspace: workspace, repo: repo)
        return .accepted
    }

    private func liveSession(_ id: SessionID) async throws -> ServerSession {
        if !changingWorkspaces.isEmpty {
            let stored = try await storedSession(id)
            if let workspaceID = stored.workspaceID, changingWorkspaces.contains(workspaceID) {
                throw ServerFailure("This workspace is being archived or restored.")
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
            guard let workspaceID = session.workspaceID,
                  let workspace = try await self.store.workspace(id: workspaceID), workspace.state == .active else {
                throw ServerFailure("This workspace is no longer available.")
            }
            return ServerSession(runner: self.makeRunner(session, workspace.path, self.store))
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
        isClosed = true
        let runningCommands = Array(commands.values)
        for command in runningCommands { command.cancel() }
        await promptQueue?.shutdown()
        await terminalStreams.shutdown()
        await terminals.shutdown()
        let liveSessions = Array(sessions.values)
        await withTaskGroup(of: Void.self) { group in
            for session in liveSessions { group.addTask { await session.shutdown() } }
        }
        for command in runningCommands { _ = await command.value }
        sessions.removeAll()
    }
}
