import Foundation
import Observation
import BloomCore

/// Remote state is kept apart from AppModel so a server path can never reach a local file action.
/// Each connection generation discards replies from an earlier server or window selection.
@MainActor
@Observable
final class ServerWindowModel {
    enum ConnectionMode { case remote, local, existingLocal }
    var connectionMode = ConnectionMode.remote
    var host = ""
    var executable = ""
    var directory = ""
    var repositoryPath = ""
    var workspaceName = ""
    var agent = AgentKind.claudeCode
    var agentModel = AppDefaults.fallbackModel
    var effort = AppDefaults.fallbackEffort
    var permissionMode = PermissionMode.plan
    var serverName = ""
    var catalogue: ServerCatalogue?
    var selectedSessionID: SessionID? {
        didSet {
            guard oldValue != selectedSessionID else { return }
            messages = []
            questions = []
            streamingText = ""
            isBusy = selectedSessionID != nil
            review.reset()
        }
    }
    var messages: [Message] = []
    var questions: [PermissionAsk] = []
    var streamingText = ""
    var draft = ""
    var isBusy = false
    var isConnecting = false
    var isPerformingCommand = false
    var error: String?
    var connectionGeneration = 0
    var showsNewWorkspace = false
    var showsReview = true
    var showsStopServerConfirmation = false
    var needsBackgroundApproval = false
    let review = ServerReviewModel()
    let localService = LocalServerService()
    private var client: ServerClient?
    private var transcriptSessionID: SessionID?
    private var uncertainRequest: ServerRequest?
    private var lastEndpoint: ServerEndpoint?

    var isConnected: Bool { client != nil }

    func connect() async {
        await disconnect()
        let generation = connectionGeneration
        isConnecting = true
        needsBackgroundApproval = false
        error = nil
        do {
            let endpoint: ServerEndpoint
            switch connectionMode {
            case .remote: endpoint = .ssh(host: host, executable: executable, directory: directory)
            case .existingLocal: endpoint = .local(directory: directory)
            case .local: endpoint = try await localService.start()
            }
            if endpoint != lastEndpoint {
                uncertainRequest = nil
                draft = ""
                lastEndpoint = endpoint
            }
            let connected = try await ServerClient.connect(to: endpoint)
            guard generation == connectionGeneration, !Task.isCancelled else {
                await connected.disconnect()
                return
            }
            client = connected
            let reply = try await connected.request(ServerRequest(.hello), timeout: .seconds(15))
            guard generation == connectionGeneration else { return }
            if case .hello(let name) = reply.result { serverName = name }
            connectionGeneration += 1
        } catch {
            if generation == connectionGeneration {
                needsBackgroundApproval = error is LocalServerServiceError
                self.error = error.localizedDescription
                await disconnect()
            }
        }
        isConnecting = false
    }

    func disconnect() async {
        connectionGeneration += 1
        let previous = client
        client = nil
        catalogue = nil
        selectedSessionID = nil
        transcriptSessionID = nil
        messages = []
        questions = []
        streamingText = ""
        isBusy = false
        review.reset()
        await previous?.disconnect()
    }

    func stopLocalServer() async {
        guard connectionMode == .local, !isPerformingCommand else { return }
        isPerformingCommand = true
        defer { isPerformingCommand = false }
        do {
            try await localService.stop()
            await disconnect()
        } catch { self.error = error.localizedDescription }
    }

    func poll() async {
        let generation = connectionGeneration
        var tick = 0
        while let client, generation == connectionGeneration, !Task.isCancelled {
            do {
                if tick % 3 == 0 {
                    let reply = try await client.request(ServerRequest(.catalogue), timeout: .seconds(15))
                    guard generation == connectionGeneration else { return }
                    if case .catalogue(let value) = reply.result { catalogue = value }
                }
                try await refreshTranscript(client: client, generation: generation)
                tick += 1
                try await Task.sleep(for: .seconds(1))
            } catch {
                guard !Task.isCancelled, generation == connectionGeneration else { return }
                self.error = error.localizedDescription
                await disconnect()
                return
            }
        }
    }

    func pollReview() async {
        let generation = connectionGeneration
        var tick = 0
        while let client, generation == connectionGeneration, !Task.isCancelled {
            if showsReview, let selectedSessionID,
               let workspaceID = catalogue?.sessions.first(where: { $0.id == selectedSessionID })?.workspaceID {
                await review.refresh(client: client, workspaceID: workspaceID, refreshFiles: tick % 3 == 0)
            }
            tick += 1
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
    }

    private func refreshTranscript(client: ServerClient, generation: Int) async throws {
        guard let id = selectedSessionID else { return }
        if transcriptSessionID != id {
            transcriptSessionID = id
            messages = []
            questions = []
            streamingText = ""
        }
        let reply = try await client.request(
            ServerRequest(.transcript(sessionID: id, afterSeq: messages.last?.seq ?? -1)), timeout: .seconds(15)
        )
        guard generation == connectionGeneration, selectedSessionID == id else { return }
        if case .transcript(let value) = reply.result {
            let cursor = messages.last?.seq ?? -1
            messages += value.messages.filter { $0.seq > cursor }
            questions = value.pendingQuestions.compactMap { PermissionAsk.decode(payload: $0) }
            isBusy = value.isBusy
            streamingText = value.streamingText
        }
    }

    func createWorkspace() async {
        let operation = ServerOperation.create(ServerWorkspaceRequest(
            repositoryPath: repositoryPath, name: workspaceName, agent: agent,
            model: agentModel, effort: effort, permissionMode: permissionMode
        ))
        if let result = await perform(operation), case .created(let session, _, let setupSucceeded) = result {
            selectedSessionID = session.id
            showsNewWorkspace = false
            if setupSucceeded == false { error = "Workspace created, but its setup script failed. Check the server before starting work." }
        }
    }

    func send() async {
        guard let id = selectedSessionID else { return }
        let text = draft
        if await perform(.send(sessionID: id, text: text)) != nil {
            if draft == text { draft = "" }
            isBusy = true
        }
    }

    func stop() async {
        guard let id = selectedSessionID else { return }
        _ = await perform(.stop(sessionID: id))
    }

    func answer(_ ask: PermissionAsk, decision: ServerAnswer) async {
        guard let id = selectedSessionID else { return }
        if await perform(.answer(sessionID: id, requestID: ask.requestID, answer: decision)) != nil {
            questions.removeAll { $0.requestID == ask.requestID }
        }
    }

    private func perform(_ operation: ServerOperation) async -> ServerResult? {
        guard let client, !isPerformingCommand else { return nil }
        isPerformingCommand = true
        defer { isPerformingCommand = false }
        let generation = connectionGeneration
        let request: ServerRequest
        if let uncertainRequest, uncertainRequest.operation == operation { request = uncertainRequest } else { request = ServerRequest(operation) }
        uncertainRequest = request
        error = nil
        do {
            let reply = try await client.request(request)
            guard generation == connectionGeneration else { return nil }
            uncertainRequest = nil
            return reply.result
        } catch {
            if generation == connectionGeneration {
                if error is ServerRefusal { uncertainRequest = nil }
                self.error = error.localizedDescription
            }
            return nil
        }
    }
}
