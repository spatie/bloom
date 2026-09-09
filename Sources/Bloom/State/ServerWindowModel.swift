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
    var usesHTTPS = false
    var httpsAddress = ""
    var isSigningIn = false
    let authentication = ServerAuthentication()
    var isConfigured: Bool { usesHTTPS ? !httpsAddress.isEmpty : !host.isEmpty }
    var connectionLabel: String { usesHTTPS ? (URL(string: httpsAddress)?.host ?? "Remote server") : (host.isEmpty ? "Remote server" : host) }
    var host = ""
    var executable = ""
    var identityFile = ""
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
    var selectedWorkspaceID: WorkspaceID?
    private var activeSessions: [WorkspaceID: SessionID] = [:]
    var selectedSessionID: SessionID? {
        didSet {
            guard oldValue != selectedSessionID else { return }
            if let id = selectedSessionID, let workspaceID = catalogue?.sessions.first(where: { $0.id == id })?.workspaceID {
                selectedWorkspaceID = workspaceID
                activeSessions[workspaceID] = id
            }
            if let oldValue { drafts[oldValue.rawValue] = draft }
            draft = selectedSessionID.flatMap { drafts[$0.rawValue] } ?? ""
            messages = []
            runScripts = []
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
    var isEditingConnection = false
    var isUploading = false
    var runScripts: [RunScript] = []
    private var terminalPanes: [String: [ServerTerminalPane]] = [:]
    private var forwards: [Int: ServerPortForward] = [:]
    var isBusy = false
    var isConnecting = false
    var isPerformingCommand = false
    var error: String?
    var connectionGeneration = 0
    var showsArchivedWorkspaces = false
    var sidebarCollapsed: Set<RepoID> = []
    var sidebarCollapseLoaded = false
    var archiveConfirmations: [UUID: (ServerEndpoint, ServerArchivePreview)] = [:]
    var archivingWorkspaceIDs: Set<WorkspaceID> = []
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
    private let messageIdentity = RemoteMessageIdentity()
    private var conversationModels: [SessionID: TranscriptModel] = [:]
    private var workspaceModels: [WorkspaceID: RemoteWorkspaceFileListing] = [:]
    var endpoint: ServerEndpoint? { lastEndpoint }

    func conversation(app: AppModel) -> TranscriptModel? {
        guard let id = selectedSessionID else { return nil }
        return conversation(id: id, app: app)
    }

    func conversation(id: SessionID, app: AppModel) -> TranscriptModel? {
        guard let session = catalogue?.sessions.first(where: { $0.id == id }),
              let workspace = catalogue?.workspaces.first(where: { $0.id == session.workspaceID }), let endpoint else { return nil }
        if let existing = conversationModels[session.id] { return existing }
        let connection = RemoteSessionConnection(server: self, endpoint: endpoint, session: session, workspace: workspace)
        let model = TranscriptModel(session: session, workspace: workspace, app: app, remote: connection)
        model.draft = drafts[session.id.rawValue] ?? ""
        conversationModels[session.id] = model
        return model
    }

    func workspaceModel(app: AppModel) -> RemoteWorkspaceFileListing? {
        guard let workspace = selectedWorkspace else { return nil }
        if let held = workspaceModels[workspace.id] { return held }
        let model = RemoteWorkspaceFileListing(workspace: workspace, server: self, app: app)
        workspaceModels[workspace.id] = model
        return model
    }
    func receiveSidebarCatalogue(_ value: ServerCatalogue) {
        catalogue = value
        for workspace in value.workspaces { workspaceModels[workspace.id]?.workspace = workspace }
    }

    func existingWorkspaceModel(_ id: WorkspaceID) -> RemoteWorkspaceFileListing? { workspaceModels[id] }
    func existingConversation(_ id: SessionID) -> TranscriptModel? { conversationModels[id] }
    func forgetConversation(_ id: SessionID) { conversationModels[id] = nil }

    func activeSession(in workspaceID: WorkspaceID) -> SessionID? {
        let sessions = catalogue?.sessions.filter { $0.workspaceID == workspaceID && $0.archivedAt == nil }
        if let held = activeSessions[workspaceID], sessions == nil || sessions?.contains(where: { $0.id == held }) == true { return held }
        return sessions?.first?.id
    }
    func activateSession(_ id: SessionID?, in workspaceID: WorkspaceID) {
        activeSessions[workspaceID] = id
        preferences.set(Dictionary(uniqueKeysWithValues: activeSessions.map { ($0.key.rawValue, $0.value.rawValue) }), forKey: "server.activeSessions")
        if selectedWorkspaceID == workspaceID { selectedSessionID = id }
    }
    func selectWorkspace(_ id: WorkspaceID) {
        selectedWorkspaceID = id
        selectedSessionID = activeSession(in: id)
    }

    func saveRemoteDraft(_ text: String, sessionID: SessionID) {
        drafts[sessionID.rawValue] = text
        preferences.set(drafts, forKey: "server.drafts")
        if selectedSessionID == sessionID { draft = text }
    }

    func read(_ operation: ServerOperation) async throws -> ServerResult {
        guard let client else { throw ServerFailure("Connect to the server first.") }
        let generation = connectionGeneration
        let reply = try await client.request(ServerRequest(operation))
        guard generation == connectionGeneration else { throw ServerFailure("The server connection changed. Try again.") }
        return reply.result
    }
    private var terminals: [String: BloomTerminalView] = [:]
    private var fileBuffers: [String: ServerFileBuffer] = [:]
    @ObservationIgnored private var editingSessions: [String: FileEditSession] = [:]

    func fileEdits(for workspace: Workspace) -> FileEditSession {
        let endpoint = lastEndpoint ?? .local(directory: "")
        let key = String(reflecting: endpoint) + "/" + workspace.id.rawValue
        if let held = editingSessions[key] { return held }
        let session = RemoteFileEditing.make(server: self, workspace: workspace, endpoint: endpoint)
        editingSessions[key] = session
        return session
    }
    func forgetArchivedWorkspace(_ id: WorkspaceID) {
        workspaceModels[id] = nil
        let prefix = String(reflecting: endpoint ?? .local(directory: "")) + "/" + id.rawValue
        editingSessions = editingSessions.filter { $0.key != prefix }
        fileBuffers = fileBuffers.filter { !$0.key.hasPrefix(prefix + "/") }
        let terminalPrefix = host + remoteDirectory + id.rawValue + "/"
        for key in terminals.keys.filter({ $0.hasPrefix(terminalPrefix) }) { terminals.removeValue(forKey: key)?.shutdown() }
        for session in catalogue?.sessions.filter({ $0.workspaceID == id }) ?? [] { conversationModels[session.id] = nil }
    }

    private let preferences: UserDefaults

    init(preferences: UserDefaults = .standard, bundle: Bundle = .main) {
        self.preferences = preferences
        if let saved = preferences.dictionary(forKey: "server.activeSessions") as? [String: String] {
            activeSessions = Dictionary(uniqueKeysWithValues: saved.map { (WorkspaceID($0.key), SessionID($0.value)) })
        }
        if let data = preferences.data(forKey: "server.terminalPanes"),
           let saved = try? JSONDecoder().decode([String: [ServerTerminalPane]].self, from: data) { terminalPanes = saved }
        let seed = bundle.object(forInfoDictionaryKey: "BloomRemoteConnection") as? [String: String] ?? [:]
        let saved = preferences.dictionary(forKey: "server.connection") as? [String: String] ?? [:]
        let values = seed.merging(saved) { _, saved in saved }
        usesHTTPS = values["usesHTTPS"] == "true"
        httpsAddress = values["httpsAddress"] ?? ""
        drafts = preferences.dictionary(forKey: "server.drafts") as? [String: String] ?? [:]
        host = values["host"] ?? ""
        executable = values["executable"] ?? ""
        identityFile = values["identityFile"] ?? ""
        remoteDirectory = values["directory"] ?? ""
        remoteRepositoryPath = values["repository"] ?? ""
        localRepositoryPath = values["localRepository"] ?? ""
        agent = values["agent"].flatMap(AgentKind.init(rawValue:))
            ?? (bundle.bundleIdentifier == Store.remoteBundleIdentifier ? .codex : AppDefaults.fallbackBackend)
        agentModel = values["model"] ?? (agent == .codex ? "" : AppDefaults.fallbackModel)
        effort = values["effort"] ?? AppDefaults.fallbackEffort
        permissionMode = (values["permissionMode"].flatMap(PermissionMode.init(rawValue:)) ?? .plan).nearest(on: agent)
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
            "usesHTTPS": usesHTTPS ? "true" : "false", "httpsAddress": httpsAddress,
            "host": host, "executable": executable, "directory": remoteDirectory, "identityFile": identityFile,
            "repository": remoteRepositoryPath, "localRepository": localRepositoryPath,
            "model": agentModel, "agent": agent.rawValue, "effort": effort, "permissionMode": permissionMode.rawValue,
        ], forKey: "server.connection")
    }

    var isConnected: Bool { client != nil }

    var selectedSession: Session? { catalogue?.sessions.first { $0.id == selectedSessionID } }
    var selectedWorkspace: Workspace? {
        let id = selectedWorkspaceID ?? selectedSession?.workspaceID
        return catalogue?.workspaces.first { $0.id == id }
    }

    func forwardedAddress(_ text: String) async throws -> String {
        guard let endpoint, let input = BrowserAddress.url(from: text),
              var components = URLComponents(url: input, resolvingAgainstBaseURL: false) else {
            throw ServerFailure("Enter an HTTP or HTTPS address.")
        }
        let generation = connectionGeneration
        do {
            if ServerPreview.isLoopback(input) {
                if case .text(let address) = try await read(.previewAddress(input.absoluteString)),
                   address != input.absoluteString {
                    guard generation == connectionGeneration, !Task.isCancelled else { throw CancellationError() }
                    return address
                }
                if case .https = endpoint { throw ServerFailure("Register this preview port with the HTTPS gateway first.") }
                let port = input.port ?? (input.scheme == "https" ? 443 : 80)
                var forward = forwards[port]
                if await forward?.isAlive != true {
                    forward = try await ServerPortForward.connect(endpoint: endpoint, remotePort: port)
                    guard generation == connectionGeneration, !Task.isCancelled else {
                        await forward?.close()
                        throw CancellationError()
                    }
                    forwards[port] = forward
                }
                components.host = "127.0.0.1"
                components.port = await forward?.localPort
            }
            guard generation == connectionGeneration, let result = components.url else { throw CancellationError() }
            return result.absoluteString
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
            throw error
        }
    }

    func displayAddress(_ text: String) async -> String {
        guard var url = URLComponents(string: text), url.host == "127.0.0.1", let port = url.port else { return text }
        for (remote, forward) in forwards where await forward.localPort == port {
            url.host = "localhost"
            url.port = remote
            return url.string ?? text
        }
        return text
    }

    private var terminalNames: [String: String] {
        get { preferences.dictionary(forKey: "server.tabTerminalNames") as? [String: String] ?? [:] }
        set { preferences.set(newValue, forKey: "server.tabTerminalNames") }
    }

    func terminalName(for tab: CenterTab) -> String { terminalNames[tab.id] ?? tab.id }

    func prepareTabs(for workspace: Workspace) {
        let tabs = CenterTabStore.shared
        tabs.load(workspaceID: workspace.id)
        let key = "server.sharedTabs." + workspace.id.rawValue
        if !preferences.bool(forKey: key) {
            let legacy = [ServerTerminalPane(id: "main", title: "Terminal")] + (terminalPanes[workspace.id.rawValue] ?? [])
            for pane in legacy {
                let tab = tabs.add(kind: .terminal, workspaceID: workspace.id, title: pane.title)
                terminalNames[tab.id] = pane.id.rawValue
            }
            preferences.set(true, forKey: key)
        }
        for tab in tabs.tabs(for: workspace.id) where tab.kind == .terminal {
            let capturedEndpoint = endpoint
            let name = terminalName(for: tab)
            tabs.onClose(tab) { [weak self] in
                guard let self, let capturedEndpoint, self.endpoint == capturedEndpoint else { return false }
                guard await self.perform(.workspace(workspaceID: workspace.id, action: .closeTerminal(name: name))) != nil else { return false }
                let key = String(reflecting: capturedEndpoint) + workspace.id.rawValue + "/" + name
                self.terminals.removeValue(forKey: key)?.shutdown()
                self.terminalNames[tab.id] = nil
                return true
            }
        }
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
        if let model = workspaceModels[workspace.id], let path = review.selectedPath { FileReview.open(path: path, in: model) }
    }

    func pullRequestURL(workspaceID: WorkspaceID) async -> String? {
        guard let client else { return nil }
        do {
            let reply = try await client.request(ServerRequest(.workspace(workspaceID: workspaceID, action: .pullRequest)), timeout: .seconds(30))
            if case .text(let url) = reply.result, URL(string: url)?.scheme == "https" { return url }
        } catch { /* A failed metadata refresh must not block the workspace's other actions. */ }
        return nil
    }

    func workspaceAction(_ action: ServerWorkspaceAction) async -> ServerResult? {
        guard let id = selectedWorkspace?.id else { return nil }
        return await perform(.workspace(workspaceID: id, action: action))
    }

    func editBuffer() -> ServerFileBuffer? {
        guard let workspace = selectedWorkspace, let path = review.selectedPath,
              let endpoint = lastEndpoint, !review.fileRevision.isEmpty else { return nil }
        let file = ServerTextFile(path: path, text: review.fileText)
        return holdEditBuffer(file, workspaceID: workspace.id, endpoint: endpoint)
    }

    func cachedEditBuffer(path: String, workspaceID: WorkspaceID) -> ServerFileBuffer? {
        guard let endpoint else { return nil }
        return fileBuffers[String(reflecting: endpoint) + "/" + workspaceID.rawValue + "/" + path]
    }

    func loadEditBuffer(path: String, workspaceID: WorkspaceID) async -> ServerFileBuffer? {
        guard let endpoint else { return nil }
        do {
            guard case .file(let file) = try await read(.file(workspaceID: workspaceID, path: path)) else { return nil }
            return holdEditBuffer(file, workspaceID: workspaceID, endpoint: endpoint)
        } catch {
            if selectedWorkspace?.id == workspaceID { self.error = error.localizedDescription }
            return nil
        }
    }

    private func holdEditBuffer(_ file: ServerTextFile, workspaceID: WorkspaceID, endpoint: ServerEndpoint) -> ServerFileBuffer {
        let key = String(reflecting: endpoint) + "/" + workspaceID.rawValue + "/" + file.path
        if let buffer = fileBuffers[key] { buffer.receive(file); return buffer }
        let buffer = ServerFileBuffer(file: file, workspaceID: workspaceID, endpoint: endpoint)
        fileBuffers[key] = buffer
        return buffer
    }

    func reloadFile(_ buffer: ServerFileBuffer) async {
        guard let client, lastEndpoint == buffer.endpoint, !buffer.isSaving else { return }
        buffer.isSaving = true
        defer { buffer.isSaving = false }
        let original = buffer.text
        do {
            let reply = try await client.request(ServerRequest(.file(workspaceID: buffer.workspaceID, path: buffer.path)))
            if case .file(let file) = reply.result { buffer.reload(file, replacing: original) }
        } catch { buffer.error = error.localizedDescription }
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
        let key = String(reflecting: endpoint) + workspace.id.rawValue + "/" + name
        if let terminal = terminals[key], !terminal.hasExited { return terminal }
        if case .https(let address) = endpoint {
            let view = BloomTerminalView(frame: .zero)
            let connection = try RemoteTerminalConnection(address: address, workspaceID: workspace.id, name: name, authentication: authentication)
            view.startRemote(connection)
            terminals[key] = view
            return view
        }
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
        defer { isConnecting = false }
        var stage = usesHTTPS ? "Connecting over HTTPS" : "Connecting over SSH"
        needsBackgroundApproval = false
        error = nil
        do {
            let endpoint: ServerEndpoint
            switch connectionMode {
            case .remote:
                if usesHTTPS { endpoint = .https(url: try ServerHTTPTransport.origin(httpsAddress).absoluteString) } else { endpoint = .ssh(host: host, executable: executable, directory: directory, identityFile: identityFile.isEmpty ? nil : identityFile) }
            case .existingLocal: endpoint = .local(directory: directory)
            case .local: endpoint = try await localService.start()
            }
            if endpoint != lastEndpoint {
                messageIdentity.reset()
                conversationModels.removeAll()
                workspaceModels.removeAll()
                sidebarCollapseLoaded = false
                sidebarCollapsed = []
                archiveConfirmations = [:]
                uncertainRequest = nil
                if lastEndpoint != nil {
                    for terminal in terminals.values { terminal.shutdown() }
                    terminals.removeAll()
                    selectedSessionID = nil
                    selectedWorkspaceID = nil
                    catalogue = nil
                    messages = []
                    review.reset()
                    for forward in forwards.values { await forward.close() }
                    forwards.removeAll()
                }
                lastEndpoint = endpoint
            }
            var accessToken: ServerHTTPTransport.AccessToken?
            if case .https(let address) = endpoint {
                accessToken = { [authentication] in try await authentication.token(for: address) }
            }
            let connected = try await ServerClient.connect(to: endpoint, accessToken: accessToken)
            guard generation == connectionGeneration, !Task.isCancelled else {
                await connected.disconnect()
                return
            }
            client = connected
            stage = "Reading server identity"
            let reply = try await connected.request(ServerRequest(.hello), timeout: .seconds(15))
            guard generation == connectionGeneration else { return }
            if case .hello(let name) = reply.result { serverName = name }
            stage = "Loading workspaces"
            let listed = try await connected.request(ServerRequest(.catalogue), timeout: .seconds(15))
            guard generation == connectionGeneration else { return }
            if case .catalogue(let value) = listed.result { catalogue = value }
            connectionGeneration += 1
        } catch {
            if generation == connectionGeneration {
                needsBackgroundApproval = error is LocalServerServiceError
                self.error = stage + ": " + error.localizedDescription
                await disconnect()
            }
        }
    }

    func disconnect() async {
        connectionGeneration += 1
        let previous = client
        client = nil
        await previous?.disconnect()
    }

    /// Tear down only Mac-side transports. The server's agents, shells and queued prompts stay.
    func shutdown() async {
        for model in conversationModels.values { await model.saveDraft() }
        shouldReconnect = false
        await disconnect()
        for terminal in terminals.values { terminal.shutdown() }
        terminals.removeAll()
        let tunnels = Array(forwards.values)
        forwards.removeAll()
        await withTaskGroup(of: Void.self) { group in
            for tunnel in tunnels { group.addTask { await tunnel.close() } }
        }
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
            if shouldReconnect, !isEditingConnection, !isConnected, !isConnecting, isConfigured {
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

    func runScript(_ script: RunScript) async {
        guard let workspace = selectedWorkspace else { return }
        if case .terminalPane(let pane) = await workspaceAction(.runScript(id: script.id)) {
            rememberTerminal(pane, workspaceID: workspace.id)
        }
    }

    private func rememberTerminal(_ pane: ServerTerminalPane, workspaceID: WorkspaceID) {
        if terminalPanes[workspaceID.rawValue]?.contains(where: { $0.id == pane.id }) != true {
            terminalPanes[workspaceID.rawValue, default: []].append(pane)
        }
        if let data = try? JSONEncoder().encode(terminalPanes) { preferences.set(data, forKey: "server.terminalPanes") }
        if let workspace = catalogue?.workspaces.first(where: { $0.id == workspaceID }) {
            let tab = CenterTabStore.shared.add(kind: .terminal, workspaceID: workspaceID, title: pane.title)
            terminalNames[tab.id] = pane.id.rawValue
            prepareTabs(for: workspace)
            if let model = workspaceModels[workspaceID] { WorkspaceTabsStore.shared.reveal(.tool(tab.id), in: model) }
        }
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
                    if let workspace = selectedWorkspace {
                        let scripts = try await client.request(ServerRequest(.workspace(workspaceID: workspace.id, action: .runScripts)), timeout: .seconds(15))
                        if generation == connectionGeneration, selectedWorkspace?.id == workspace.id,
                           case .runScripts(let value) = scripts.result { runScripts = value }
                    }
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
            if showsReview, let workspaceID = selectedWorkspace?.id {
                await review.refresh(client: client, workspaceID: workspaceID, refreshFiles: tick % 3 == 0)
            }
            tick += 1
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
    }

    private func refreshTranscript(client: ServerClient, generation: Int) async throws {
        guard let workspaceID = selectedWorkspace?.id else { return }
        let ids = Set(conversationModels.keys.filter { id in
            catalogue?.sessions.contains { $0.id == id && $0.workspaceID == workspaceID && $0.archivedAt == nil } == true
        } + (selectedSessionID.map { [$0] } ?? []))
        for id in ids {
            let cursor = conversationModels[id]?.remoteCursor ?? -1
            let reply = try await client.request(ServerRequest(.transcript(sessionID: id, afterSeq: cursor)), timeout: .seconds(15))
            guard generation == connectionGeneration else { return }
            guard case .transcript(let value) = reply.result else { continue }
            let fresh = value.messages.map { messageIdentity.presentation($0) }
            conversationModels[id]?.receiveRemote(value, messages: fresh)
            if selectedSessionID == id {
                if transcriptSessionID != id { messages = []; transcriptSessionID = id }
                let previous = messages.last?.seq ?? -1
                messages += fresh.filter { $0.seq > previous }
                questions = value.pendingQuestions.compactMap { PermissionAsk.decode(payload: $0) }
                permissionDecisions = value.permissionDecisions
                queuedPrompts = value.queuedPrompts
                queueError = value.queueError
                isBusy = value.isBusy
                streamingText = value.streamingText
            }
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
        if let result = await perform(operation), case .created(let session, let workspace, let setupSucceeded) = result {
            if catalogue?.workspaces.contains(where: { $0.id == workspace.id }) == false { catalogue?.workspaces.append(workspace) }
            if catalogue?.sessions.contains(where: { $0.id == session.id }) == false { catalogue?.sessions.append(session) }
            selectedSessionID = session.id
            showsNewWorkspace = false
            if setupSucceeded == false { error = "Workspace created, but its setup script failed. Check the server before starting work." }
        }
    }

    func send() async {
        guard let id = selectedSessionID else { return }
        let text = draft
        if await perform(.send(sessionID: id, text: text)) != nil {
            if selectedSessionID == id {
                if draft == text { draft = "" }
                isBusy = true
            } else if drafts[id.rawValue] == text {
                drafts[id.rawValue] = ""
                preferences.set(drafts, forKey: "server.drafts")
            }
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

    func perform(_ operation: ServerOperation) async -> ServerResult? {
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
