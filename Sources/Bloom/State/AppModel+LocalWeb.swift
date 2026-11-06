import AppKit
import Foundation
import BloomCore

/// Browser access to this running Bloom instance. The listener owns no runner or database; every
/// prompt uses the same transcript model as the Mac window, and all reads use its Store actor.
extension AppModel {
    func setLocalWebEnabled(_ enabled: Bool) {
        guard localWebEnabled != enabled else { return }
        localWebEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "localWeb.enabled")
        if enabled {
            startLocalWebIfEnabled()
        } else {
            let unsent = localWebUploads.values.flatMap { $0 }
            localWebUploads.removeAll()
            Task.detached(priority: .utility) {
                for upload in unsent { AttachmentFiles.discard(upload.attachment, workspace: upload.root) }
            }
            localWebServer?.stop()
            localWebServer = nil
            localWebAddress = nil
            localWebToken = nil
            localWebConnectTicket = nil
            localWebError = nil
        }
    }

    func startLocalWebIfEnabled() {
        guard isLoaded, localWebEnabled, localWebServer == nil, store != nil else { return }
        localWebError = nil
        localWebConnectTicket = nil
        let token = BridgeRegistry.randomToken()
        do {
            let server = try LocalWebServer(
                port: LocalWebDevelopment.enabled ? LocalWebDevelopment.port : nil,
                handler: { [weak self] request in
                    guard let self else { return .text(503, "Bloom is closing") }
                    return await self.localWebResponse(to: request, token: token)
                },
                onReady: { [weak self] port in
                    Task { @MainActor [weak self] in
                        guard let self, self.localWebToken == token else { return }
                        self.localWebAddress = "http://127.0.0.1:\(port)"
                    }
                },
                onFailure: { [weak self] message in
                    Task { @MainActor [weak self] in
                        guard let self, self.localWebToken == token else { return }
                        self.localWebError = message
                        self.localWebAddress = nil
                    }
                }
            )
            localWebToken = token
            localWebServer = server
            server.start()
        } catch {
            localWebError = error.localizedDescription
        }
    }

    /// A short-lived link for a browser opened on this Mac. The URL carries only a one-use ticket;
    /// the long-lived access code is returned to that page after the ticket is consumed.
    func localWebBrowserURL() -> URL? {
        guard localWebEnabled, let address = localWebAddress,
              var components = URLComponents(string: address) else { return nil }
        let ticket = BridgeRegistry.randomToken()
        localWebConnectTicket = (ticket, Date().addingTimeInterval(60))
        components.fragment = "connect=\(ticket)"
        return components.url
    }

    func openLocalWebInBrowser() {
        guard let url = localWebBrowserURL() else { return }
        NSWorkspace.shared.open(url)
    }

    private func localWebResponse(to request: LocalWebServer.Request, token: String) async -> LocalWebServer.Response {
        guard localWebEnabled, localWebToken == token else { return .text(503, "Browser access is off") }
        if request.method == "GET", request.path == "/" {
            let nonce = BridgeRegistry.randomToken()
            return .init(
                contentType: "text/html; charset=utf-8",
                body: Data(LocalWebPage.html(nonce: nonce, devBrowser: LocalWebDevelopment.enabled).utf8),
                contentSecurityPolicy: "default-src 'none'; script-src 'nonce-\(nonce)'; "
                    + "connect-src 'self'; style-src 'unsafe-inline'; img-src 'self' data:; "
                    + "base-uri 'none'; form-action 'self'"
            )
        }
        if request.method == "GET", request.path == "/assets/bloom-mark.svg" {
            guard let url = Bundle.main.url(forResource: "BloomMark", withExtension: "svg"),
                  let data = try? Data(contentsOf: url) else { return .text(404, "Bloom mark unavailable") }
            return .init(contentType: "image/svg+xml", body: data)
        }
        if request.method == "POST", request.path == "/api/dev-connect" {
            guard LocalWebDevelopment.enabled, LocalWebDevelopment.accepts(request) else {
                return .text(404, "Not found")
            }
            return json(WebConnectResponse(token: token))
        }
        if request.method == "POST", request.path == "/api/connect" {
            guard let input: WebConnectRequest = decode(request),
                  let pending = localWebConnectTicket,
                  pending.value == input.ticket, pending.expiresAt > Date() else {
                return .text(401, "This browser link has expired. Open it again from Bloom Settings")
            }
            localWebConnectTicket = nil
            return json(WebConnectResponse(token: token))
        }
        guard request.headers["authorization"] == "Bearer \(token)" else {
            return .text(401, "Enter the access code from Bloom Settings")
        }
        guard let store else { return .text(503, "Bloom is loading") }
        let parts = request.path.split(separator: "/").map(String.init)
        do {
            if request.method == "GET", parts == ["api", "projects"] {
                return json(try await store.repos().filter { !$0.hidden }.map {
                    WebProject(id: $0.id, name: $0.name, path: $0.path,
                               branch: $0.defaultBranch, accent: $0.accent)
                })
            }
            if request.method == "POST", parts == ["api", "projects"] {
                guard let input: WebProjectRequest = decode(request) else { return .text(400, "Enter a project path") }
                if let name = input.name, let location = input.location {
                    let facts = NewProjectStarter.inspect(name: name, location: location)
                    switch ProjectTargetVerdict.of(facts) {
                    case .create, .adopt: break
                    case .add: return .text(400, "This is already a repository. Use Add existing project.")
                    case .track: return .text(400, "This folder has files. Use the Mac app's Start Tracking flow to review its first commit.")
                    case .refuse: return .text(400, "Bloom cannot create a project at this location.")
                    }
                    do {
                        let created = try await NewProjectStarter.create(at: facts.path)
                        let repo = try await WorkspaceManager(store: store).addRepository(at: created.path)
                        return json(WebProject(id: repo.id, name: repo.name, path: repo.path,
                                               branch: repo.defaultBranch, accent: repo.accent))
                    } catch {
                        return .text(400, error.localizedDescription)
                    }
                }
                return await webTool("project_add", arguments: ["path": .string(input.path ?? "")], store: store)
            }
            if request.method == "POST", parts == ["api", "workspaces"] {
                guard let input: WebWorkspaceRequest = decode(request), !input.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return .text(400, "Enter a task for the new workspace")
                }
                var arguments: [String: JSONValue] = ["project": .string(input.project), "prompt": .string(input.prompt)]
                if let name = input.name, !name.isEmpty { arguments["name"] = .string(name) }
                if let branch = input.baseBranch, !branch.isEmpty { arguments["base_branch"] = .string(branch) }
                return await webTool("workspace_start", arguments: arguments, store: store)
            }
            if request.method == "GET", parts == ["api", "conversations"] {
                return json(try await store.sessionsWithoutWorkspace().map {
                    WebChat(id: $0.id, title: ChatListTool.title(of: $0), agent: $0.agentKind.rawValue,
                            model: $0.model, effort: $0.effort, state: $0.state.rawValue)
                })
            }
            if request.method == "POST", parts == ["api", "conversations"] {
                await ask.newConversation()
                guard let session = ask.session else { return .text(503, "Bloom could not create the conversation") }
                return json(WebChat(id: session.id, title: ChatListTool.title(of: session),
                                    agent: session.agentKind.rawValue, model: session.model,
                                    effort: session.effort, state: session.state.rawValue))
            }
            if request.method == "POST", parts.count == 4, parts[0] == "api",
               parts[1] == "workspaces", parts[3] == "chats" {
                guard let input: WebChatRequest = decode(request) else { return .text(400, "Invalid chat request") }
                var arguments: [String: JSONValue] = ["workspace": .string(parts[2]), "terminal_chat": .bool(false)]
                if let title = input.title, !title.isEmpty { arguments["title"] = .string(title) }
                return await webTool("chat_create", arguments: arguments, store: store)
            }
            if request.method == "GET", parts.count == 4, parts[0] == "api",
               parts[1] == "workspaces", parts[3] == "changes" {
                guard let workspace = try await store.workspace(id: WorkspaceID(parts[2])), workspace.state == .active else {
                    return .text(404, "Workspace not found")
                }
                let files = try await Git.changedFiles(worktree: workspace.path, base: workspace.comparisonBase)
                return json(files.map {
                    WebChangedFile(path: $0.path, change: $0.change.rawValue,
                                   additions: $0.additions, deletions: $0.deletions)
                })
            }
            if request.method == "GET", parts.count == 4, parts[0] == "api",
               parts[1] == "workspaces", parts[3] == "files" {
                guard let workspace = try await store.workspace(id: WorkspaceID(parts[2])), workspace.state == .active else {
                    return .text(404, "Workspace not found")
                }
                return webFileResponse(target: request.target, root: workspace.path)
            }
            if request.method == "GET", parts.count == 4, parts[0] == "api",
               parts[1] == "chats", parts[3] == "files" {
                guard let session = try await store.session(id: SessionID(parts[2])), session.archivedAt == nil else {
                    return .text(404, "Chat not found")
                }
                let root: String
                if let workspaceID = session.workspaceID,
                   let workspace = try await store.workspace(id: workspaceID), workspace.state == .active {
                    root = workspace.path
                } else if session.workspaceID == nil {
                    let saved = try await store.setting(AskTabs.directoryKey(session.id))
                    guard let directory = AskTabs.prepareDirectory(saved ?? "", databasePath: store.path) else {
                        return .text(404, "Conversation folder not found")
                    }
                    root = directory
                } else { return .text(404, "Chat not found") }
                return webFileResponse(target: request.target, root: root)
            }
            if request.method == "POST", parts.count == 4, parts[0] == "api",
               parts[1] == "chats", parts[3] == "attachments" {
                let sessionID = SessionID(parts[2])
                guard let session = try await store.session(id: sessionID), session.archivedAt == nil,
                      request.headers["content-type"]?.hasPrefix("application/octet-stream") == true,
                      let named = request.headers["x-bloom-filename"]?.removingPercentEncoding,
                      !named.isEmpty, named.utf8.count <= 512,
                      !named.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                      !request.body.isEmpty, request.body.count <= 25 * 1_024 * 1_024 else {
                    return .text(400, "Choose a file up to 25 MB")
                }
                let root: String
                if let workspaceID = session.workspaceID,
                   let workspace = try await store.workspace(id: workspaceID), workspace.state == .active {
                    root = workspace.path
                } else if session.workspaceID == nil {
                    await ask.open()
                    await ask.select(sessionID)
                    guard let directory = ask.paneState(for: sessionID)?.directory else {
                        return .text(404, "Conversation folder not found")
                    }
                    root = directory
                } else { return .text(404, "Chat not found") }
                let filename = PromptAttachments.safeFilename(named)
                let bytes = request.body
                do {
                    let attachment = try await Task.detached(priority: .userInitiated) {
                        let directory = FileManager.default.temporaryDirectory
                            .appending(path: "bloom-web-upload-\(UUID().uuidString)")
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        defer { try? FileManager.default.removeItem(at: directory) }
                        let source = directory.appending(path: filename)
                        try bytes.write(to: source, options: .atomic)
                        return try AttachmentFiles.attach(.file(source), workspace: root)
                    }.value
                    localWebUploads[sessionID, default: []].append(
                        LocalWebUpload(attachment: attachment, root: root)
                    )
                    return json(WebUploadedAttachment(
                        path: attachment.path, name: attachment.filename,
                        token: AttachmentDraft.token(for: attachment.path)
                    ))
                } catch {
                    return .text(400, error.readableMessage)
                }
            }
            if request.method == "POST", parts.count == 5, parts[0] == "api",
               parts[1] == "chats", parts[3] == "attachments", parts[4] == "remove" {
                guard let input: WebRemoveAttachment = decode(request) else { return .text(400, "Name an attachment") }
                let sessionID = SessionID(parts[2])
                var uploads = localWebUploads[sessionID] ?? []
                guard let index = uploads.firstIndex(where: { $0.attachment.path == input.path }) else {
                    return .text(404, "Attachment not found")
                }
                let removed = uploads.remove(at: index)
                localWebUploads[sessionID] = uploads
                await Task.detached(priority: .utility) {
                    AttachmentFiles.discard(removed.attachment, workspace: removed.root)
                }.value
                return json(WebAccepted(accepted: true))
            }
            if request.method == "POST", parts.count == 5, parts[0] == "api",
               parts[1] == "chats", parts[3] == "permissions" {
                guard let input: WebPermissionAnswer = decode(request),
                      let session = try await store.session(id: SessionID(parts[2])), session.archivedAt == nil else {
                    return .text(400, "Permission request not found")
                }
                let transcript: TranscriptModel
                if let workspaceID = session.workspaceID,
                   let workspace = try await store.workspace(id: workspaceID), workspace.state == .active {
                    let model = model(for: workspace)
                    if !model.hasReadSessions { await model.reloadSessions() }
                    guard let current = model.sessions.first(where: { $0.id == session.id }) else {
                        return .text(404, "Chat not found")
                    }
                    transcript = model.transcript(for: current)
                } else if session.workspaceID == nil {
                    await ask.open()
                    await ask.select(session.id)
                    guard let current = ask.transcript(for: session.id) else { return .text(404, "Chat not found") }
                    transcript = current
                } else { return .text(404, "Chat not found") }
                await transcript.load()
                guard transcript.isRunning,
                      let pending = transcript.pendingPermissionAsks.first(where: { $0.requestID == parts[4] }) else {
                    return .text(404, "Permission request is no longer pending")
                }
                guard let decision = webPermissionDecision(input, for: pending) else {
                    return .text(400, "This answer does not match the pending request")
                }
                await transcript.answer(requestID: parts[4], decision: decision)
                return json(WebAccepted(accepted: true))
            }
            if request.method == "GET", parts == ["api", "workspaces"] {
                let workspaces = try await store.workspaces()
                let repos = Dictionary(uniqueKeysWithValues: try await store.repos()
                    .filter { !$0.hidden }.map { ($0.id, $0.name) })
                return json(workspaces.filter { repos[$0.repoID] != nil }.map { workspace in
                    WebWorkspace(
                        id: workspace.id, name: workspace.name,
                        project: repos[workspace.repoID] ?? "Project", projectID: workspace.repoID,
                        branch: workspace.branch
                    )
                })
            }
            if request.method == "GET", parts.count == 4, parts[0] == "api",
               parts[1] == "workspaces", parts[3] == "chats" {
                let workspaceID = WorkspaceID(parts[2])
                guard let workspace = try await store.workspace(id: workspaceID), workspace.state == .active else {
                    return .text(404, "Workspace not found")
                }
                let sessions = try await store.sessions(workspaceID: workspaceID)
                return json(sessions.filter { $0.parentSessionID == nil }.map { session in
                    WebChat(
                        id: session.id, title: ChatListTool.title(of: session),
                        agent: session.agentKind.rawValue, model: session.model,
                        effort: session.effort, state: session.state.rawValue
                    )
                })
            }
            if parts.count == 4, parts[0] == "api", parts[1] == "chats", parts[3] == "composer" {
                return await localWebComposerResponse(request, sessionID: SessionID(parts[2]), store: store)
            }
            if parts.count == 4, parts[0] == "api", parts[1] == "chats", parts[3] == "quick-prompts" {
                return await localWebQuickPromptsResponse(request, sessionID: SessionID(parts[2]), store: store)
            }
            if request.method == "POST", parts.count == 4, parts[0] == "api",
               parts[1] == "chats", parts[3] == "side-question" {
                return await localWebSideQuestionResponse(request, sessionID: SessionID(parts[2]), store: store)
            }
            if parts.count == 4, parts[0] == "api", parts[1] == "chats", parts[3] == "messages" {
                let sessionID = SessionID(parts[2])
                guard let session = try await store.session(id: sessionID),
                      session.archivedAt == nil else {
                    return .text(404, "Chat not found")
                }
                let workspaceID = session.workspaceID
                let workspace: Workspace?
                if let workspaceID {
                    workspace = try await store.workspace(id: workspaceID)
                } else {
                    workspace = nil
                }
                guard workspaceID == nil || workspace?.state == .active else { return .text(404, "Chat not found") }
                if request.method == "GET" {
                    let components = URLComponents(string: "http://localhost\(request.target)")
                    let after = components?.queryItems?.first(where: { $0.name == "after" })?.value.flatMap(Int.init)
                    let before = components?.queryItems?.first(where: { $0.name == "before" })?.value.flatMap(Int.init)
                    let fetched = if let before {
                        try await store.messages(sessionID: sessionID, beforeSeq: before, limit: 201)
                    } else if let after {
                        try await store.messages(sessionID: sessionID, afterSeq: after, limit: 200)
                    } else {
                        try await store.recentMessages(sessionID: sessionID, limit: 201)
                    }
                    let hasMoreEarlier = (before != nil || after == nil) && fetched.count > 200
                    let messages = hasMoreEarlier ? Array(fetched.dropFirst()) : fetched
                    let highest = messages.last?.seq ?? after ?? -1
                    let first = messages.first?.seq ?? before ?? -1
                    let streaming = if let workspaceID {
                        existingModel(for: workspaceID)?.existingTranscript(for: sessionID)?.streamingText ?? ""
                    } else { ask.transcript(for: sessionID)?.streamingText ?? "" }
                    let decisions = try await store.permissionAskDecisions(sessionID: sessionID)
                    let savedDirectory = workspace == nil
                        ? try await store.setting(AskTabs.directoryKey(sessionID)) : nil
                    let worktree = workspace?.path
                        ?? AskTabs.prepareDirectory(savedDirectory ?? "", databasePath: store.path)
                        ?? ""
                    // Provider decoding and Markdown highlighting can walk large rows. Keep that
                    // work off the main actor that also drives the Mac transcript.
                    let (rows, streamingHTML) = await Task.detached(priority: .utility) {
                        (
                            messages.compactMap { TranscriptClientRow.present($0, worktree: worktree) },
                            MarkdownHTML.render(streaming, imagesAsAltText: true).html
                        )
                    }.value
                    return json(WebMessages(
                        schemaVersion: 1, messages: rows, firstSeq: first, lastSeq: highest,
                        hasMoreEarlier: hasMoreEarlier, streaming: streaming,
                        streamingHTML: streamingHTML, decisions: decisions
                    ))
                }
                if request.method == "POST" {
                    guard request.headers["content-type"]?.hasPrefix("application/json") == true,
                          let prompt = try? JSONDecoder().decode(WebPrompt.self, from: request.body),
                          !prompt.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          prompt.text.count <= 32_000 else { return .text(400, "Enter a prompt up to 32,000 characters") }
                    if let question = SideConversation.question(in: prompt.text) {
                        return await localWebSideQuestion(question, sessionID: sessionID, store: store)
                    }
                    let sent: Bool
                    if let workspace {
                        let model = model(for: workspace)
                        if !model.hasReadSessions { await model.reloadSessions() }
                        guard let current = model.sessions.first(where: { $0.id == sessionID }) else {
                            return .text(404, "Chat not found")
                        }
                        sent = await model.transcript(for: current).submit(prompt.text)
                    } else {
                        await ask.open()
                        await ask.select(sessionID)
                        sent = await ask.transcript(for: sessionID)?.submit(prompt.text) == true
                    }
                    if sent {
                        let named = Set(AttachmentDraft.parse(prompt.text).paths)
                        localWebUploads[sessionID]?.removeAll { named.contains($0.attachment.path) }
                    }
                    return sent ? json(WebAccepted(accepted: true)) : .text(503, "Bloom could not send this prompt")
                }
            }
            return .text(404, "Not found")
        } catch {
            return .text(500, "Bloom could not complete this request")
        }
    }

    private func json<T: Encodable>(_ value: T) -> LocalWebServer.Response {
        guard let data = try? JSONEncoder().encode(value) else { return .text(500, "Could not encode response") }
        return .init(body: data)
    }

    private func webFileResponse(target: String, root: String) -> LocalWebServer.Response {
        let components = URLComponents(string: "http://localhost\(target)")
        guard let path = components?.queryItems?.first(where: { $0.name == "path" })?.value,
              !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
              let url = ContainedPath.resolve(URL(filePath: root).appending(path: path), inside: URL(filePath: root)),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize else {
            return .text(404, "File not found inside this conversation")
        }
        let imageTypes = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
                          "gif": "image/gif", "webp": "image/webp"]
        if let mime = imageTypes[url.pathExtension.lowercased()], size <= 5_242_880,
           let data = try? Data(contentsOf: url) {
            return json(WebFile(path: path, content: nil,
                                imageDataURL: "data:\(mime);base64,\(data.base64EncodedString())"))
        }
        guard size <= 1_048_576, let content = try? String(contentsOf: url, encoding: .utf8),
              !content.contains("\0") else { return .text(404, "Preview unavailable for this file") }
        return json(WebFile(path: path, content: content, imageDataURL: nil))
    }

    private func decode<T: Decodable>(_ request: LocalWebServer.Request) -> T? {
        guard request.headers["content-type"]?.hasPrefix("application/json") == true else { return nil }
        return try? JSONDecoder().decode(T.self, from: request.body)
    }

    private func webPermissionDecision(_ input: WebPermissionAnswer, for ask: PermissionAsk) -> PermissionDecision? {
        switch input.decision {
        case "allow_once" where !ask.isQuestion && !ask.isPlanApproval:
            return .allow(scope: .once)
        case "deny" where !ask.isQuestion && !ask.isPlanApproval:
            return .deny(message: "", endsTurn: false)
        case "approve_plan" where ask.isPlanApproval:
            let mode = input.mode.flatMap(PermissionMode.init(rawValue:))
                ?? PlanApproval.implementationMode(ask.implementationMode ?? .acceptEdits)
            guard input.mode == nil || PermissionMode(rawValue: input.mode ?? "") != nil,
                  PlanApproval.modes.contains(mode) else { return nil }
            return .approvePlan(mode: mode)
        case "keep_planning" where ask.isPlanApproval:
            return .deny(message: PlanApproval.keepPlanningMessage, endsTurn: false)
        case "answer" where ask.isQuestion:
            let questions = AgentQuestionnaire.questions(in: ask.input)
            let choices = input.choices ?? [:]
            let other = input.other ?? [:]
            let ids = Set(questions.map(\.id))
            guard Set(choices.keys).isSubset(of: ids), Set(other.keys).isSubset(of: ids) else { return nil }
            var draft = AgentQuestionDraft()
            for question in questions {
                let selected = choices[question.id] ?? []
                guard question.multiSelect || selected.count <= 1,
                      Set(selected).count == selected.count,
                      selected.allSatisfy({ label in question.options.contains { $0.label == label } }) else {
                    return nil
                }
                for label in selected { draft.toggle(label, on: question) }
                if let written = other[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !written.isEmpty {
                    guard question.allowsOther, written.count <= 4_000 else { return nil }
                    draft.writeOther(on: question)
                    draft.other[question.id] = written
                }
            }
            guard draft.isComplete(questions) else { return nil }
            return .answer(input: AgentQuestionnaire.answered(ask.input, answers: draft.answers(to: questions)))
        default:
            return nil
        }
    }

    private func webTool(_ name: String, arguments: [String: JSONValue], store: Store) async -> LocalWebServer.Response {
        guard let handler = bridgeToolbox().handler(named: name, for: .owner) else { return .text(404, "Command unavailable") }
        let result = await handler.call(MCPRequest(id: .integer(1), method: "tools/call", params: .object(arguments)), as: .owner, store: store)
        if result.isError { return .text(400, result.text) }
        return .init(body: Data(result.text.utf8))
    }
}

/// Bloom Dev is a separate app and database. Its local browser may connect without a copied
/// code, while another host or a reverse proxy still follows the ordinary access-code path.
private enum LocalWebDevelopment {
    static let port: UInt16 = 53_544

    static var enabled: Bool { Bundle.main.bundleIdentifier == Store.devBundleIdentifier }

    static func accepts(_ request: LocalWebServer.Request) -> Bool {
        let localOrigin = "http://127.0.0.1:\(port)"
        return request.headers["host"] == "127.0.0.1:\(port)"
            && request.headers["origin"] == localOrigin
            && request.headers["forwarded"] == nil
            && request.headers["x-forwarded-for"] == nil
            && request.headers["x-forwarded-host"] == nil
            && request.headers["x-real-ip"] == nil
            && request.body.isEmpty
    }
}

struct LocalWebUpload: Sendable {
    let attachment: PromptAttachment
    let root: String
}

private struct WebProject: Encodable {
    let id: RepoID
    let name: String
    let path: String
    let branch: String
    let accent: String
}

private struct WebConnectRequest: Decodable { let ticket: String }
private struct WebConnectResponse: Encodable { let token: String }

private struct WebProjectRequest: Decodable {
    let path: String?
    let name: String?
    let location: String?
}

private struct WebWorkspaceRequest: Decodable {
    let project: String
    let prompt: String
    let name: String?
    let baseBranch: String?
}

private struct WebChatRequest: Decodable { let title: String? }
private struct WebUploadedAttachment: Encodable { let path: String; let name: String; let token: String }
private struct WebRemoveAttachment: Decodable { let path: String }
private struct WebPermissionAnswer: Decodable {
    let decision: String
    let choices: [String: [String]]?
    let other: [String: String]?
    let mode: String?
}
private struct WebFile: Encodable { let path: String; let content: String?; let imageDataURL: String? }
private struct WebChangedFile: Encodable {
    let path: String
    let change: String
    let additions: Int
    let deletions: Int
}

private struct WebWorkspace: Encodable {
    let id: WorkspaceID
    let name: String
    let project: String
    let projectID: RepoID
    let branch: String
}

private struct WebChat: Encodable {
    let id: SessionID
    let title: String
    let agent: String
    let model: String
    let effort: String
    let state: String
}

private struct WebPrompt: Decodable {
    let text: String
}

private struct WebAccepted: Encodable {
    let accepted: Bool
}

private struct WebMessages: Encodable {
    let schemaVersion: Int
    let messages: [TranscriptClientRow]
    let firstSeq: Int
    let lastSeq: Int
    let hasMoreEarlier: Bool
    let streaming: String
    let streamingHTML: String
    let decisions: [String: String]
}
