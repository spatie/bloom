import Foundation

/// The standalone runtime is the single owner of its store and its session runners. Clients
/// request snapshots and commands, never open its SQLite file or launch a second runner.
public actor ServerRuntime {
    public typealias RunnerFactory = @Sendable (Session, String, Store) -> any SessionRunner
    private let store: Store
    private let makeRunner: RunnerFactory
    private var sessions: [SessionID: ServerSession] = [:]
    private var creating: [SessionID: Task<ServerSession, Error>] = [:]
    private var commands: [UUID: Task<ServerReply, Never>] = [:]
    private var commandOperations: [UUID: ServerOperation] = [:]
    private var stopping: [SessionID: Int] = [:]
    private var isClosed = false

    public init(store: Store, makeRunner: @escaping RunnerFactory = { session, path, store in
        SessionRunnerFactory.make(session: session, workspacePath: path, store: store)
    }) {
        self.store = store
        self.makeRunner = makeRunner
    }

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
        case .catalogue:
            let workspaces = try await store.workspaces()
            var storedSessions: [Session] = []
            for workspace in workspaces { storedSessions += try await store.sessions(workspaceID: workspace.id) }
            return .catalogue(ServerCatalogue(
                repositories: try await store.repos(), workspaces: workspaces, sessions: storedSessions
            ))
        case .create(let request):
            guard request.agent.canRunWorkspaces else { throw ServerFailure("This agent backend is not supported.") }
            guard !request.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !request.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  request.repositoryPath.hasPrefix("/") else {
                throw ServerFailure("Enter a workspace name, model and an absolute repository path on the server.")
            }
            let manager = WorkspaceManager(store: store)
            let repo = try await manager.addRepository(at: request.repositoryPath)
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
            return .transcript(ServerTranscript(
                session: session,
                messages: try await store.messages(sessionID: id, afterSeq: afterSeq, limit: 500),
                pendingQuestions: try await store.pendingPermissionAsks(sessionID: id).map { $0.ask.raw },
                isBusy: await live?.isBusy ?? false,
                streamingText: await live?.streamingText ?? ""
            ))
        case .send(let id, let text):
            guard stopping[id] == nil else { throw ServerFailure("This session is being stopped.") }
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty, body.utf8.count <= 1_048_576 else { throw ServerFailure("The prompt is empty or too large.") }
            let live = try await liveSession(id)
            try await live.refreshState(store: store, sessionID: id)
            guard stopping[id] == nil else { throw ServerFailure("This session is being stopped.") }
            try await live.send(body)
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
            await sessions[id]?.stop()
            return .accepted
        case .answer(let id, let requestID, let answer):
            guard let live = sessions[id] else { throw ServerFailure("This session has no running agent.") }
            try await live.answer(requestID: requestID, decision: answer.decision, store: store, sessionID: id)
            return .accepted
        }
    }

    private func storedSession(_ id: SessionID) async throws -> Session {
        guard let session = try await store.session(id: id) else { throw ServerFailure("This session no longer exists.") }
        return session
    }

    private func workspace(_ id: WorkspaceID) async throws -> Workspace {
        guard let workspace = try await store.workspace(id: id), workspace.state == .active else {
            throw ServerFailure("This workspace is no longer available.")
        }
        return workspace
    }

    private func liveSession(_ id: SessionID) async throws -> ServerSession {
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
        let liveSessions = Array(sessions.values)
        await withTaskGroup(of: Void.self) { group in
            for session in liveSessions { group.addTask { await session.shutdown() } }
        }
        for command in runningCommands { _ = await command.value }
        sessions.removeAll()
    }
}
