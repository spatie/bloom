import Foundation
import Observation
import BloomCore

/// The transport behind a normal conversation. It supplies data and actions, never UI.
@MainActor
@Observable
final class RemoteSessionConnection {
    private weak var server: ServerWindowModel?
    private let endpoint: ServerEndpoint
    let sessionID: SessionID
    let workspace: Workspace
    var controls: ComposerControls
    let models = ComposerModelCatalog()
    let commands = SlashCommandCatalog()
    let styles = ComposerOutputStyleCatalog()
    private(set) var isPreparing = false
    private(set) var isApplying = false
    private(set) var isUploading = false
    private var prepared = false
    let attachmentCache: String

    init(server: ServerWindowModel, endpoint: ServerEndpoint, session: Session, workspace: Workspace) {
        self.server = server
        self.endpoint = endpoint
        self.sessionID = session.id
        self.workspace = workspace
        controls = ComposerControls(session: session, isFastMode: false, outputStyle: OutputStyle.defaultName)
        attachmentCache = FileManager.default.temporaryDirectory.appendingPathComponent("bloom-remote-previews/\(UUID().uuidString)").path
    }

    var canSend: Bool { server?.isConnected == true && server?.endpoint == endpoint && !isApplying && !isUploading }

    private func request(_ operation: ServerOperation) async throws -> ServerResult {
        guard let server, server.endpoint == endpoint else { throw ServerFailure("Reconnect to this workspace's server.") }
        return try await server.read(operation)
    }

    private func perform(_ operation: ServerOperation) async -> ServerResult? {
        guard let server, server.endpoint == endpoint else { return nil }
        return await server.perform(operation)
    }

    func prepare() async {
        guard !prepared, !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }
        do {
            guard case .composer(let state) = try await request(.composer(sessionID: sessionID)) else { return }
            controls = state.controls
            models.receive(state.models, availableAgents: state.availableAgents)
            // Source-file previews require a fetched local copy. Never hand a server path to a
            // component that reads the Mac filesystem.
            commands.receive(state.commands.map { var command = $0; command.path = nil; return command })
            styles.receive(state.styles)
            prepared = true
        } catch { if !Task.isCancelled { server?.error = error.localizedDescription } }
    }

    func apply(_ value: ComposerControls) async -> Session? {
        guard !isApplying else { return nil }
        isApplying = true
        defer { isApplying = false }
        switch await perform(.setComposer(sessionID: sessionID, controls: value)) {
        case .accepted:
            controls = value
            return nil
        case .created(let session, _, _):
            server?.catalogue?.sessions.append(session)
            return session
        default: return nil
        }
    }

    func submit(_ text: String) async -> Bool { await perform(.send(sessionID: sessionID, text: text)) != nil }
    func submit(_ text: String, to id: SessionID) async -> Bool { await perform(.send(sessionID: id, text: text)) != nil }
    func stop() async { _ = await perform(.stop(sessionID: sessionID)) }
    func answer(requestID: String, decision: PermissionDecision) async {
        _ = await perform(.answer(sessionID: sessionID, requestID: requestID, answer: ServerAnswer(decision)))
    }
    func cancel(_ id: DeliveryID) async -> Bool {
        await perform(.cancelQueued(sessionID: sessionID, deliveryID: id)) != nil
    }
    func markRead(_ seq: Int) async { _ = try? await request(.markRead(sessionID: sessionID, seq: seq)) }
    func saveDraft(_ text: String) {
        guard server?.endpoint == endpoint else { return }
        server?.saveRemoteDraft(text, sessionID: sessionID)
    }

    func newChat() async -> Session? {
        guard case .created(let session, _, _) = await perform(.workspace(workspaceID: workspace.id,
            action: .newSession(agent: controls.agentKind, model: controls.model, effort: controls.effort, permissionMode: controls.permissionMode))) else { return nil }
        server?.catalogue?.sessions.append(session)
        return session
    }

    func close() async -> Bool {
        guard await perform(.closeSession(sessionID: sessionID)) != nil else { return false }
        server?.forgetConversation(sessionID)
        server?.catalogue?.sessions.removeAll { $0.id == sessionID }
        return true
    }

    func saveDraft(_ text: String, for session: Session) {
        guard server?.endpoint == endpoint else { return }
        server?.saveRemoteDraft(text, sessionID: session.id)
    }

    func files() async -> [String] {
        do {
            if case .files(let paths) = try await request(.workspace(workspaceID: workspace.id, action: .files)) { return paths }
        } catch { if !Task.isCancelled { server?.error = error.localizedDescription } }
        return []
    }

    func attach(_ sources: [AttachmentSource]) async throws -> [String] {
        guard !isUploading else { throw ServerFailure("Wait for the current attachment upload.") }
        isUploading = true
        defer { isUploading = false }
        var paths: [String] = []
        for source in sources {
            let data: Data
            switch source {
            case .file(let url), .promisedFile(let url, _):
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max <= ServerFileOperations.transferLimit else {
                    throw ServerFailure("Choose a file up to 8 MB.")
                }
                data = try Data(contentsOf: url)
            case .image(let bytes, _, _): data = bytes
            case .text(let text, _): data = Data(text.utf8)
            }
            guard case .text(let path) = try await request(.workspace(workspaceID: workspace.id,
                action: .uploadFile(name: source.filename, data: data))) else { continue }
            try cache(data, at: path)
            paths.append(path)
        }
        return paths
    }

    func cacheAttachments(in text: String) async {
        for path in AttachmentDraft.parse(text).paths {
            guard let local = cacheURL(path), !FileManager.default.fileExists(atPath: local.path) else { continue }
            do {
                if case .download(let file) = try await request(.workspace(workspaceID: workspace.id, action: .download(path: path))) {
                    try cache(file.data, at: path)
                }
            } catch { /* Opening the attachment reports a missing or unavailable remote file. */ }
        }
    }

    private func cacheURL(_ path: String) -> URL? {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."), !path.contains("\0") else { return nil }
        return URL(fileURLWithPath: attachmentCache).appendingPathComponent(path)
    }

    private func cache(_ data: Data, at path: String) throws {
        guard let url = cacheURL(path) else { throw ServerFailure("The server returned an invalid attachment path.") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func openFile(_ path: String) {
        guard server?.endpoint == endpoint, server?.selectedWorkspace?.id == workspace.id else { return }
        server?.openFile(path)
    }
}
