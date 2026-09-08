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
    var remoteDirectory = ""
    var existingLocalDirectory = ""
    var directory: String {
        get { connectionMode == .existingLocal ? existingLocalDirectory : remoteDirectory }
        set { if connectionMode == .existingLocal { existingLocalDirectory = newValue } else { remoteDirectory = newValue } }
    }
    var workspaceDestination = ConnectionMode.remote
    var remoteRepositoryPath = ""
    var localRepositoryPath = ""
    var repositoryPath: String {
        get { workspaceDestination == .remote ? remoteRepositoryPath : localRepositoryPath }
        set { if workspaceDestination == .remote { remoteRepositoryPath = newValue } else { localRepositoryPath = newValue } }
    }
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
            if let oldValue { drafts[oldValue.rawValue] = draft }
            draft = selectedSessionID.flatMap { drafts[$0.rawValue] } ?? ""
            messages = []
            questions = []
            queuedPrompts = []
            queueError = nil
            streamingText = ""
            isBusy = selectedSessionID != nil
            review.reset()
        }
    }
    var messages: [Message] = []
    var questions: [PermissionAsk] = []
    var queuedPrompts: [ServerQueuedPrompt] = []
    var queueError: String?
    var permissionDecisions: [String: String] = [:]
    var streamingText = ""
    var draft = "" {
        didSet {
            if let selectedSessionID { drafts[selectedSessionID.rawValue] = draft }
            preferences.set(drafts, forKey: "server.drafts")
        }
    }
    private var drafts: [String: String] = [:]
    var shouldReconnect = true
    var isUploading = false
    var activePane = "chat"
    var previewAddress = "http://localhost:8000"
    var browser: BrowserSession?
    private var forwards: [Int: ServerPortForward] = [:]
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
    private var terminals: [String: BloomTerminalView] = [:]
    private var fileBuffers: [String: ServerFileBuffer] = [:]
    private let preferences: UserDefaults

    init(preferences: UserDefaults = .standard, bundle: Bundle = .main) {
        self.preferences = preferences
        let seed = bundle.object(forInfoDictionaryKey: "BloomRemoteConnection") as? [String: String] ?? [:]
        let saved = preferences.dictionary(forKey: "server.connection") as? [String: String] ?? [:]
        let values = seed.merging(saved) { _, saved in saved }
        drafts = preferences.dictionary(forKey: "server.drafts") as? [String: String] ?? [:]
        host = values["host"] ?? ""
        executable = values["executable"] ?? ""
        remoteDirectory = values["directory"] ?? ""
        remoteRepositoryPath = values["repository"] ?? ""
        localRepositoryPath = values["localRepository"] ?? ""
        if bundle.bundleIdentifier == Store.remoteBundleIdentifier {
            agent = .codex
            agentModel = values["model"] ?? "gpt-5.6-sol"
        }
    }

    var destinationLabel: String { connectionMode == .remote ? "Remote server" : "This Mac" }

    func prepareNewWorkspace() {
        workspaceDestination = connectionMode
        showsNewWorkspace = true
    }

    func switchMachine(_ destination: ConnectionMode) async {
        guard !isConnecting, !isPerformingCommand else { return }
        connectionMode = destination
        await connect()
    }

    private func saveConnection() {
        preferences.set([
            "host": host, "executable": executable, "directory": remoteDirectory,
            "repository": remoteRepositoryPath, "localRepository": localRepositoryPath,
            "model": agentModel,
        ], forKey: "server.connection")
    }

    var isConnected: Bool { client != nil }

    var selectedSession: Session? { catalogue?.sessions.first { $0.id == selectedSessionID } }
    var selectedWorkspace: Workspace? {
        guard let session = selectedSession else { return nil }
        return catalogue?.workspaces.first { $0.id == session.workspaceID }
    }

    func preview(_ url: URL? = nil) async {
        guard let endpoint = lastEndpoint, let input = url ?? URL(string: previewAddress),
              ["http", "https"].contains(input.scheme), var components = URLComponents(url: input, resolvingAgainstBaseURL: false) else {
            error = "Enter an HTTP or HTTPS address."; return
        }
        do {
            if ["localhost", "127.0.0.1", "::1", "[::1]", "0.0.0.0"].contains(input.host ?? "") {
                let port = input.port ?? (input.scheme == "https" ? 443 : 80)
                var forward = forwards[port]
                if await forward?.isAlive != true {
                    forward = try await ServerPortForward.connect(endpoint: endpoint, remotePort: port)
                    forwards[port] = forward
                }
                components.host = "127.0.0.1"
                components.port = await forward?.localPort
            }
            guard let forwarded = components.url else { return }
            browser = BrowserSession(url: forwarded.absoluteString)
            previewAddress = input.absoluteString
            activePane = "preview"
        } catch { self.error = error.localizedDescription }
    }

    func download(_ path: String, workspaceID: WorkspaceID) async throws -> URL {
        guard let client else { throw ServerFailure("Connect to the server to download this file.") }
        let reply = try await client.request(ServerRequest(.workspace(workspaceID: workspaceID, action: .download(path: path))))
        guard case .download(let file) = reply.result else { throw ServerFailure("The server did not return a file.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BloomRemotePreviews").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let local = folder.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
        try file.data.write(to: local, options: .atomic)
        return local
    }

    func openFile(_ path: String) {
        guard let workspace = selectedWorkspace else { return }
        let prefix = workspace.path.hasSuffix("/") ? workspace.path : workspace.path + "/"
        review.showsFile = true
        review.selectedPath = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
        showsReview = true
    }

    func workspaceAction(_ action: ServerWorkspaceAction) async -> ServerResult? {
        guard let id = selectedWorkspace?.id else { return nil }
        return await perform(.workspace(workspaceID: id, action: action))
    }

    func editBuffer() -> ServerFileBuffer? {
        guard let workspace = selectedWorkspace, let path = review.selectedPath,
              let endpoint = lastEndpoint, !review.fileRevision.isEmpty else { return nil }
        let key = host + remoteDirectory + workspace.id.rawValue + "/" + path
        let file = ServerTextFile(path: path, text: review.fileText)
        if let buffer = fileBuffers[key] { buffer.receive(file); return buffer }
        let buffer = ServerFileBuffer(file: file, workspaceID: workspace.id, endpoint: endpoint)
        fileBuffers[key] = buffer
        return buffer
    }

    func saveFile(_ buffer: ServerFileBuffer) async {
        guard let client, lastEndpoint == buffer.endpoint, !buffer.isSaving else { return }
        buffer.isSaving = true
        defer { buffer.isSaving = false }
        let text = buffer.text
        do {
            let reply = try await client.request(ServerRequest(.workspace(workspaceID: buffer.workspaceID,
                action: .writeFile(path: buffer.path, text: text, revision: buffer.revision))))
            if case .file(let file) = reply.result { buffer.saved(file, submitted: text) }
        } catch { buffer.error = error.localizedDescription }
    }

    func terminal(named name: String = "main") async throws -> BloomTerminalView {
        guard let workspace = selectedWorkspace, let client, let endpoint = lastEndpoint else {
            throw ServerFailure("Connect to this workspace's server first.")
        }
        let key = host + remoteDirectory + workspace.id.rawValue + "/" + name
        if let terminal = terminals[key], !terminal.hasExited { return terminal }
        let reply = try await client.request(ServerRequest(.workspace(workspaceID: workspace.id, action: .terminal(name: name))))
        guard case .terminal(let terminal) = reply.result else { throw ServerFailure("The server did not return a terminal.") }
        let launch = try endpoint.terminalLaunch(terminal)
        var environment = launch.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        let view = BloomTerminalView(frame: .zero)
        view.start(TerminalLaunch(
            executable: launch.executable, execName: "ssh", arguments: launch.arguments,
            environment: environment.map { "\($0.key)=\($0.value)" }.sorted(), directory: launch.cwd
        ))
        terminals[key] = view
        return view
    }

    func connect() async {
        guard !isConnecting else { return }
        shouldReconnect = true
        saveConnection()
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
                if lastEndpoint != nil {
                    selectedSessionID = nil
                    catalogue = nil
                    messages = []
                    review.reset()
                    browser = nil
                    for forward in forwards.values { await forward.close() }
                    forwards.removeAll()
                }
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
            let listed = try await connected.request(ServerRequest(.catalogue), timeout: .seconds(15))
            guard generation == connectionGeneration else { return }
            if case .catalogue(let value) = listed.result { catalogue = value }
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
        await previous?.disconnect()
    }

    func stopLocalServer() async {
        guard connectionMode == .local, !isPerformingCommand else { return }
        isPerformingCommand = true
        defer { isPerformingCommand = false }
        do {
            try await localService.stop()
            shouldReconnect = false
            await disconnect()
        } catch { self.error = error.localizedDescription }
    }

    /// Keep the last readable snapshot while SSH reconnects. Agent ownership never follows the UI.
    func maintainConnection() async {
        var delay = 1
        while !Task.isCancelled {
            if shouldReconnect, !isConnected, !isConnecting, !host.isEmpty {
                await connect()
                delay = isConnected ? 1 : min(30, delay * 2)
            } else { delay = 1 }
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
        }
    }

    func configure(model: String, effort: String, permissionMode: PermissionMode) async {
        guard let id = selectedSessionID else { return }
        _ = await perform(.configure(sessionID: id, model: model, effort: effort, permissionMode: permissionMode))
    }

    func newChat() async -> SessionID? {
        guard let session = selectedSession else { return nil }
        let result = await workspaceAction(.newSession(agent: session.agentKind, model: session.model,
            effort: session.effort, permissionMode: session.permissionMode))
        if case .created(let created, _, _) = result {
            catalogue?.sessions.append(created)
            return created.id
        }
        return nil
    }

    func upload(_ sources: [AttachmentSource]) async {
        guard let workspaceID = selectedWorkspace?.id, let client, !isUploading else { return }
        let sessionID = selectedSessionID
        isUploading = true
        defer { isUploading = false }
        do {
            for source in sources {
                let data: Data
                switch source {
                case .file(let url), .promisedFile(let url, _):
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                    guard size <= ServerFileOperations.transferLimit else { throw ServerFailure("Choose a file up to 8 MB.") }
                    data = try Data(contentsOf: url)
                case .image(let bytes, _, _): data = bytes
                case .text(let text, _): data = Data(text.utf8)
                }
                let reply = try await client.request(ServerRequest(.workspace(workspaceID: workspaceID,
                    action: .uploadFile(name: source.filename, data: data))))
                if case .text(let path) = reply.result {
                    let addition = " `" + path + "` "
                    if selectedSessionID == sessionID { draft += addition } else if let sessionID { drafts[sessionID.rawValue, default: ""] += addition }
                }
            }
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
            queuedPrompts = []
            queueError = nil
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
            permissionDecisions = value.permissionDecisions
            queuedPrompts = value.queuedPrompts
            queueError = value.queueError
            isBusy = value.isBusy
            streamingText = value.streamingText
        }
    }

    func createWorkspace() async {
        guard !isConnecting, !isPerformingCommand else { return }
        if workspaceDestination != connectionMode || !isConnected {
            connectionMode = workspaceDestination
            await connect()
            guard isConnected else { return }
        }
        saveConnection()
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

    func cancelQueued(_ id: DeliveryID) async {
        guard let sessionID = selectedSessionID else { return }
        _ = await perform(.cancelQueued(sessionID: sessionID, deliveryID: id))
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
