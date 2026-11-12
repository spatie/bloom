import BloomCore
import Foundation

/// The browser reads and changes the same composer state as the Mac footer. Agent choices stay
/// on `ComposerControls`, while the session and its extra settings remain in Bloom's Store.
extension AppModel {
    func localWebComposerResponse(
        _ request: LocalWebServer.Request, sessionID: SessionID, store: Store
    ) async -> LocalWebServer.Response {
        do {
            guard let context = try await webComposerContext(sessionID, store: store) else {
                return .text(404, "Chat not found")
            }
            await ComposerPlanningSupport.shared.refresh(from: store)
            if request.method == "GET" {
                return webComposerJSON(await webComposerSnapshot(context, store: store))
            }
            guard request.method == "POST",
                  request.headers["content-type"]?.hasPrefix("application/json") == true,
                  let change = try? JSONDecoder().decode(WebComposerChange.self, from: request.body) else {
                return .text(400, "Invalid composer change")
            }
            return await webChangeComposer(change, context: context, store: store)
        } catch {
            return .text(500, "Bloom could not read this chat's composer")
        }
    }

    private func webComposerContext(_ id: SessionID, store: Store) async throws -> WebComposerContext? {
        guard let stored = try await store.session(id: id), stored.archivedAt == nil else { return nil }
        if let workspaceID = stored.workspaceID {
            guard let workspace = try await store.workspace(id: workspaceID), workspace.state == .active else {
                return nil
            }
            let model = model(for: workspace)
            if !model.hasReadSessions { await model.reloadSessions() }
            guard let session = model.sessions.first(where: { $0.id == id }) else { return nil }
            let transcript = model.transcript(for: session)
            await transcript.load()
            return WebComposerContext(session: transcript.session, workspace: workspace,
                                      model: model, transcript: transcript)
        }
        await ask.open()
        if ask.transcript(for: id) == nil { await ask.select(id) }
        guard let transcript = ask.transcript(for: id) else { return nil }
        await transcript.load()
        return WebComposerContext(session: transcript.session, workspace: nil,
                                  model: nil, transcript: transcript)
    }

    private func webComposerControls(_ context: WebComposerContext, store: Store) async throws -> ComposerControls {
        let id = context.session.id
        let fast = try await store.setting(ComposerControls.fastModeKey(sessionID: id)) == "1"
        let codexFast = CodexSpeed.override(stored: try await store.setting(CodexSpeed.key(sessionID: id)))
        let style = try await store.setting(ComposerControls.outputStyleKey(sessionID: id))
            ?? OutputStyle.defaultName
        let window = CodexContextWindow.normalised(try await store.setting(
            ComposerControls.contextWindowKey(sessionID: id)
        ))
        // Read even though this page has no advisor picker: a change saves every key.
        let advisor = ChatAdvisor(stored: try await store.setting(ChatAdvisor.key(sessionID: id)))
        return ComposerControls(session: context.session, isFastMode: fast, outputStyle: style,
                                codexContextWindow: window, codexFastMode: codexFast, advisor: advisor)
    }

    private func webComposerSnapshot(_ context: WebComposerContext, store: Store) async -> WebComposerSnapshot {
        let controls = (try? await webComposerControls(context, store: store))
            ?? ComposerControls(session: context.session, isFastMode: false, outputStyle: OutputStyle.defaultName)
        let catalog = ComposerModelCatalog.shared
        await catalog.loadReady()
        let presets = await ModelPresetList.load(from: store)
        let styleCatalog = ComposerOutputStyleCatalog.shared(for: context.workspace?.path)
        if controls.offersOutputStyle { await styleCatalog.refreshIfStale(project: context.workspace?.path) }
        let speed: CodexSpeed? = if controls.agentKind == .codex {
            try? await CodexSpeed.read(
                cwd: context.workspace?.path ?? AgentScratchDirectory.current(), modelID: controls.model
            )
        } else { nil }
        let modelSections = catalog.sections(includingCurrent: controls.model, on: controls.agentKind)
        let efforts = ComposerOption.adding([controls.effort], to: catalog.efforts(
            for: controls.agentKind, model: controls.model
        ))
        return WebComposerSnapshot(
            agent: controls.agentKind.rawValue, model: controls.model, effort: controls.effort,
            permissionMode: controls.permissionMode.rawValue,
            interactionMode: controls.interactionMode.rawValue,
            fastMode: controls.isFast(codexSpeed: speed),
            fastAvailable: controls.fastModeAvailability(
                codexSpeed: speed, codexSpeedFailed: speed == nil
            ) == .available,
            outputStyle: controls.outputStyle, contextWindow: controls.codexContextWindow,
            models: modelSections.map { section in
                WebComposerModelSection(agent: section.kind.rawValue, title: section.title,
                                        options: section.options.map(WebComposerOption.init))
            },
            efforts: efforts.map(WebComposerOption.init),
            permissionModes: controls.permissionModeChoices.map {
                WebComposerOption(value: $0.mode.rawValue, label: $0.label, detail: $0.summary)
            },
            outputStyles: controls.offersOutputStyle
                ? styleCatalog.options(includingCurrent: controls.outputStyle).map(WebComposerOption.init) : [],
            contextWindows: controls.offersContextWindow
                ? CodexContextWindow.options(including: controls.codexContextWindow).map {
                    WebComposerWindow(tokens: $0, label: CodexContextWindow.label(for: $0))
                } : [],
            presets: presets.presets.map { WebComposerPreset(key: $0.id.rawValue, name: $0.name) },
            matchedPreset: presets.matching(controls)?.id.rawValue,
            offersInteractionMode: controls.offersInteractionMode,
            planAvailable: ComposerPlanningSupport.shared.isAvailable,
            contextUsed: context.transcript.contextUsage?.used,
            contextLimit: context.transcript.contextUsage?.limit,
            canSideQuestion: context.workspace != nil && context.session.sideConversationParentID == nil
        )
    }

    private func webChangeComposer(
        _ change: WebComposerChange, context: WebComposerContext, store: Store
    ) async -> LocalWebServer.Response {
        guard let current = try? await webComposerControls(context, store: store) else {
            return .text(503, "Composer settings are unavailable")
        }
        var chosen = current
        let catalog = ComposerModelCatalog.shared
        await catalog.loadReady()
        switch change.field {
        case "preset":
            let list = await ModelPresetList.load(from: store)
            guard let key = change.value,
                  let preset = list.presets.first(where: { $0.id.rawValue == key }) else {
                return .text(400, "Choose a saved preset")
            }
            chosen = chosen.applying(preset)
            chosen.effort = catalog.resolvedEffort(chosen.effort, for: chosen.agentKind, model: chosen.model)
            if chosen.interactionMode == .plan, !ComposerPlanningSupport.shared.isAvailable {
                return .text(400, "Planning is unavailable for this chat")
            }
        case "model":
            let sections = catalog.sections(includingCurrent: current.model, on: current.agentKind)
            guard let section = sections.first(where: { $0.options.contains(where: { $0.id == change.value }) }),
                  let value = change.value else { return .text(400, "Choose an available model") }
            chosen.model = value
            chosen.agentKind = section.kind
            chosen.effort = catalog.resolvedEffort(chosen.effort, for: section.kind, model: value)
        case "effort":
            guard let value = change.value,
                  ComposerOption.adding([current.effort], to: catalog.efforts(
                    for: current.agentKind, model: current.model
                  )).contains(where: { $0.id == value }) else { return .text(400, "Choose an available effort") }
            chosen.effort = value
        case "permissionMode":
            guard let value = change.value.flatMap(PermissionMode.init(rawValue:)),
                  chosen.availablePermissionModes.contains(value) else {
                return .text(400, "Choose an available permission mode")
            }
            chosen.permissionMode = value
        case "interactionMode":
            guard let value = change.value.flatMap(InteractionMode.init(rawValue:)),
                  value.nearest(on: chosen.agentKind) == value,
                  value != .plan || ComposerPlanningSupport.shared.isAvailable else {
                return .text(400, "This work mode is unavailable")
            }
            chosen.interactionMode = value
        case "fastMode":
            guard let enabled = change.enabled,
                  chosen.agentKind == .claudeCode || chosen.agentKind == .codex else {
                return .text(400, "Fast mode is unavailable")
            }
            if chosen.agentKind == .codex {
                guard let speed = try? await CodexSpeed.read(
                    cwd: context.workspace?.path ?? AgentScratchDirectory.current(), modelID: chosen.model
                ), speed.supportsFast else { return .text(400, "Fast mode is unavailable for this model") }
            }
            chosen = chosen.settingFastMode(enabled)
        case "outputStyle":
            guard chosen.offersOutputStyle, let value = change.value else {
                return .text(400, "Output styles are unavailable")
            }
            let styles = ComposerOutputStyleCatalog.shared(for: context.workspace?.path)
            await styles.refreshIfStale(project: context.workspace?.path)
            guard styles.options(includingCurrent: current.outputStyle).contains(where: { $0.id == value }) else {
                return .text(400, "Choose an available output style")
            }
            chosen.outputStyle = value
        case "contextWindow":
            guard chosen.offersContextWindow, let tokens = change.tokens,
                  CodexContextWindow.options(including: current.codexContextWindow).contains(tokens) else {
                return .text(400, "Choose an available context window")
            }
            chosen.codexContextWindow = tokens
        default:
            return .text(400, "Unknown composer setting")
        }
        guard chosen != current else {
            return webComposerJSON(WebComposerChangeResult(chatID: context.session.id, forked: false))
        }
        let spoken = BackendChange.hasSpoken(
            rowCount: context.transcript.rows.count,
            agentSessionID: context.session.agentSessionID,
            isTranscriptLoaded: context.transcript.isLoaded
        )
        if case .fork(let kind) = BackendChange.decide(
            from: context.session.agentKind, to: chosen.agentKind, hasSpoken: spoken
        ) {
            if let model = context.model {
                guard let made = await model.createSession(
                    title: BackendChange.forkedTitle(context.session.title, to: kind),
                    controls: chosen, draft: change.draft ?? ""
                ) else { return .text(503, "Could not open the new chat") }
                return webComposerJSON(WebComposerChangeResult(chatID: made.id, forked: true))
            }
            await ask.startFresh(controls: chosen, draft: change.draft ?? "")
            guard let made = ask.session, made.id != context.session.id else {
                return .text(503, "Could not open the new conversation")
            }
            return webComposerJSON(WebComposerChangeResult(chatID: made.id, forked: true))
        }
        do {
            try await store.saveComposerControls(chosen, sessionID: context.session.id)
            await context.transcript.updatePreferences(
                model: chosen.model, effort: chosen.effort, permissionMode: chosen.permissionMode,
                interactionMode: chosen.interactionMode, agentKind: chosen.agentKind
            )
            if let model = context.model { await model.reloadSessions() }
            return webComposerJSON(WebComposerChangeResult(chatID: context.session.id, forked: false))
        } catch {
            return .text(500, "Could not save composer settings")
        }
    }

    func localWebQuickPromptsResponse(
        _ request: LocalWebServer.Request, sessionID: SessionID, store: Store
    ) async -> LocalWebServer.Response {
        do {
            guard let context = try await webComposerContext(sessionID, store: store) else {
                return .text(404, "Chat not found")
            }
            let personal = try await store.seedQuickPrompts()
            await context.model?.reloadSettings()
            let project = context.model?.settings.quickPrompts ?? []
            if request.method == "GET" {
                return webComposerJSON(
                    personal.map { WebQuickPrompt(source: "personal", key: $0.id.rawValue,
                                                  name: $0.name, preview: $0.preview,
                                                  sendsImmediately: $0.sendsImmediately,
                                                  opensNewChat: $0.opensNewChat) }
                    + project.map { WebQuickPrompt(source: "project", key: $0.id,
                                                   name: $0.name, preview: $0.preview,
                                                   sendsImmediately: false,
                                                   opensNewChat: $0.opensNewChat) }
                )
            }
            guard request.method == "POST",
                  request.headers["content-type"]?.hasPrefix("application/json") == true,
                  let input = try? JSONDecoder().decode(WebQuickPromptApply.self, from: request.body),
                  input.draft.count <= 32_000 else { return .text(400, "Invalid quick prompt request") }
            let words: String
            let title: String
            let delivery: QuickPromptDelivery
            if input.source == "personal", let prompt = personal.first(where: { $0.id.rawValue == input.key }) {
                words = prompt.text
                title = prompt.name.isEmpty ? prompt.preview : prompt.name
                delivery = QuickPromptDelivery.decided(
                    for: prompt, canSend: true, canOpenNewChat: context.model != nil
                )
            } else if input.source == "project", let prompt = project.first(where: { $0.id == input.key }) {
                words = prompt.text
                title = prompt.chatTitle
                delivery = prompt.delivery(canOpenNewChat: context.model != nil)
            } else { return .text(404, "Quick prompt not found") }
            let inserted = QuickPromptInsertion.inserting(words, into: input.draft, at: input.caret)
            switch delivery {
            case .compose:
                return webComposerJSON(WebQuickPromptResult(
                    draft: inserted.text, caret: inserted.caret, sent: false, chatID: nil
                ))
            case .send:
                guard await context.transcript.submit(inserted.text) else {
                    return .text(503, "Could not send the quick prompt")
                }
                settleWebUploads(in: inserted.text, sessionID: sessionID)
                return webComposerJSON(WebQuickPromptResult(draft: "", caret: 0, sent: true, chatID: nil))
            case .composeInNewChat, .sendInNewChat:
                guard let model = context.model,
                      let made = await model.createSession(
                        title: title, draft: delivery.sends ? "" : words
                      ) else { return .text(503, "Could not open the new chat") }
                if delivery.sends {
                    guard await model.transcript(for: made).submit(words) else {
                        return .text(503, "Could not send the quick prompt")
                    }
                }
                return webComposerJSON(WebQuickPromptResult(
                    draft: delivery.sends ? "" : words,
                    caret: delivery.sends ? 0 : (words as NSString).length,
                    sent: delivery.sends, chatID: made.id
                ))
            }
        } catch {
            return .text(500, "Bloom could not load quick prompts")
        }
    }

    func localWebSideQuestionResponse(
        _ request: LocalWebServer.Request, sessionID: SessionID, store: Store
    ) async -> LocalWebServer.Response {
        guard request.headers["content-type"]?.hasPrefix("application/json") == true,
              let input = try? JSONDecoder().decode(WebSideQuestion.self, from: request.body),
              input.question.count <= 32_000 else { return .text(400, "Enter a shorter side question") }
        return await localWebSideQuestion(input.question, sessionID: sessionID, store: store)
    }

    func localWebSideQuestion(
        _ question: String, sessionID: SessionID, store: Store
    ) async -> LocalWebServer.Response {
        do {
            guard let context = try await webComposerContext(sessionID, store: store),
                  let model = context.model, context.session.sideConversationParentID == nil else {
                return .text(404, "Side questions need a workspace chat")
            }
            let child = try await store.openSideConversation(
                parentID: sessionID, streamingText: context.transcript.streamingText
            )
            await model.reloadSessions()
            let transcript = model.transcript(for: child)
            await transcript.load()
            let body = question.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty, await transcript.submit(body) == false {
                return .text(503, "Could not send the side question")
            }
            return webComposerJSON(WebComposerChangeResult(chatID: child.id, forked: true))
        } catch {
            return .text(500, "Could not open the side question")
        }
    }

    private func settleWebUploads(in text: String, sessionID: SessionID) {
        let named = Set(AttachmentDraft.parse(text).paths)
        localWebUploads[sessionID]?.removeAll { named.contains($0.attachment.path) }
    }

    private func webComposerJSON<T: Encodable>(_ value: T) -> LocalWebServer.Response {
        guard let body = try? JSONEncoder().encode(value) else { return .text(500, "Could not encode composer") }
        return .init(body: body)
    }
}

private struct WebComposerContext {
    let session: Session
    let workspace: Workspace?
    let model: WorkspaceModel?
    let transcript: TranscriptModel
}

private struct WebComposerChange: Decodable {
    let field: String
    let value: String?
    let enabled: Bool?
    let tokens: Int?
    let draft: String?
}

private struct WebComposerChangeResult: Encodable {
    let chatID: SessionID
    let forked: Bool
}

private struct WebComposerOption: Encodable {
    let value: String
    let label: String
    let detail: String?

    init(value: String, label: String, detail: String? = nil) {
        self.value = value
        self.label = label
        self.detail = detail
    }

    init(_ option: ComposerOption) {
        self.init(value: option.id, label: option.label, detail: option.detail)
    }
}

private struct WebComposerModelSection: Encodable {
    let agent: String
    let title: String
    let options: [WebComposerOption]
}

private struct WebComposerWindow: Encodable {
    let tokens: Int
    let label: String
}

private struct WebComposerSnapshot: Encodable {
    let agent: String
    let model: String
    let effort: String
    let permissionMode: String
    let interactionMode: String
    let fastMode: Bool
    let fastAvailable: Bool
    let outputStyle: String
    let contextWindow: Int
    let models: [WebComposerModelSection]
    let efforts: [WebComposerOption]
    let permissionModes: [WebComposerOption]
    let outputStyles: [WebComposerOption]
    let contextWindows: [WebComposerWindow]
    let presets: [WebComposerPreset]
    let matchedPreset: String?
    let offersInteractionMode: Bool
    let planAvailable: Bool
    let contextUsed: Int?
    let contextLimit: Int?
    let canSideQuestion: Bool
}

private struct WebComposerPreset: Encodable {
    let key: String
    let name: String
}

private struct WebQuickPrompt: Encodable {
    let source: String
    let key: String
    let name: String
    let preview: String
    let sendsImmediately: Bool
    let opensNewChat: Bool
}

private struct WebQuickPromptApply: Decodable {
    let source: String
    let key: String
    let draft: String
    let caret: Int
}

private struct WebQuickPromptResult: Encodable {
    let draft: String
    let caret: Int
    let sent: Bool
    let chatID: SessionID?
}

private struct WebSideQuestion: Decodable {
    let question: String
}
