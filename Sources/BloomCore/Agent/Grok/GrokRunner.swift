import Foundation
import Synchronization

/// Supervises one `grok agent stdio` connection for one Bloom chat.
///
/// The shape is `CodexRunner`'s, deliberately: a long-lived process, the session id persisted the
/// moment it arrives so a crashed app can resume, every event written to the store before it
/// reaches the UI, and the same permission bookkeeping. What it is not is a second code path
/// inside `CodexRunner`. The two backends share no protocol, only the idea of a conversation, and
/// that idea is `SessionRunner`.
public actor GrokRunner: SessionRunner {
    public nonisolated let agentKind = AgentKind.grok
    public nonisolated let workspacePath: String
    public nonisolated let sessionID: SessionID

    private let store: Store
    private let makeClient: @Sendable (GrokClient.Configuration) -> GrokClient

    private var session: Session
    private var client: GrokClient?
    private var pumpTask: Task<Void, Never>?
    private var translation: GrokTranslation
    private var grokSessionID: String?
    /// Invalidates in-flight pump events when the client is replaced. A late `.closed` from a
    /// dead process must not drop the replacement.
    private var connectionGeneration: UInt64 = 0
    private var permissionConnectionID = UUID()

    private let grants: SessionGrants
    private var wireModel: String { ModelIdentifier.resolve(session.model).model }

    private var approvals: [String: GrokPermissionRequest] = [:]

    private let connection = LiveConnection()
    private let pending = PendingAsks()
    private let handle = CodexTurnHandle()
    private let sink = AgentPresentationFeed()
    private var sendsInFlight = 0
    private var wasEvicted = false
    private var trouble = PersistenceTrouble()
    private let bridge: BridgeAttachment?

    public init(
        workspacePath: String,
        session: Session,
        store: Store,
        bridge: BridgeAttachment? = nil,
        makeClient: @escaping @Sendable (GrokClient.Configuration) -> GrokClient = GrokRunner.spawn
    ) {
        self.workspacePath = workspacePath
        self.sessionID = session.id
        self.session = session
        self.store = store
        self.bridge = bridge
        self.makeClient = makeClient
        self.grants = SessionGrants(store: store, workspaceID: session.workspaceID)
        self.translation = GrokTranslation(context: GrokTranslation.Context(
            model: ModelIdentifier.resolve(session.model).model,
            cwd: workspacePath,
            permissionMode: session.permissionMode.cliValue
        ))
    }

    public static let spawn: @Sendable (GrokClient.Configuration) -> GrokClient = { configuration in
        GrokClient(configuration: configuration)
    }

    public nonisolated var events: AsyncStream<AgentEvent> { sink.stream() }
    public nonisolated var presentationFeed: AgentPresentationFeed? { sink }

    public var isProcessAlive: Bool { connection.current?.isProcessAlive ?? false }

    public var currentSession: Session { session }

    public var lastPersistenceFailure: String? { trouble.lastSentence }

    public var persistenceFailureCount: Int { trouble.failures }

    static let clientVersion = "1.0"

    // MARK: - SessionRunner

    public func send(_ text: String, recording: Data? = nil) async throws {
        try await send(text, recording: recording, deliveryID: nil, interactionMode: nil)
    }

    public func evictIfIdle(for duration: Duration) async -> Bool {
        guard !wasEvicted, sendsInFlight == 0, !session.state.isMidTurn,
              session.agentSessionID != nil, pending.isEmpty, !sink.hasBackgroundWork else { return false }
        let lastActivity = sink.lastActivity
        guard lastActivity.duration(to: .now) >= duration,
              let waiting = try? await store.pendingDeliveries(sessionID: session.id), waiting.isEmpty else { return false }
        // Recheck after the store hop. A send or a native background event invalidates the lease.
        guard sendsInFlight == 0, !session.state.isMidTurn, pending.isEmpty,
              !sink.hasBackgroundWork, sink.lastActivity == lastActivity else { return false }
        wasEvicted = true
        terminateNow()
        return true
    }

    public func sendDelivery(_ delivery: Delivery) async throws {
        try await send(delivery.sent, recording: delivery.crewPayload,
                       deliveryID: delivery.id, interactionMode: delivery.interactionMode)
    }

    private func send(_ text: String, recording: Data?, deliveryID: DeliveryID?,
                      interactionMode: InteractionMode?) async throws {
        guard !wasEvicted else { throw ProviderIdleError.retired }
        sendsInFlight += 1
        sink.noteActivity()
        defer { sendsInFlight -= 1 }
        let generation = handle.generation
        let replacement = handle.prepareReplacement()
        defer { handle.finishReplacement(replacement) }
        try handle.check(generation)
        if handle.wasCancelled {
            for event in translation.finishInterruptedTurn() { await emit(event) }
            try handle.check(generation)
        }
        let client = try await connected()
        try handle.check(generation)
        let grokSessionID = try await openSession(on: client)
        try handle.check(generation)
        try await applyComposerSettings(on: client, sessionID: grokSessionID)
        try handle.check(generation)

        if deliveryID == nil {
            if let recording { await persist(kind: .crew, payload: recording) } else { await persist(kind: .user, payload: Self.userPayload(text)) }
        }
        try handle.check(generation)

        if let deliveryID { try await store.beginDeliveryDispatch(id: deliveryID) }
        let promptID = try await client.beginPrompt(sessionID: grokSessionID, text: text)
        if let deliveryID { try await store.acceptDelivery(id: deliveryID, providerTurnID: promptID.turnID) }
        guard handle.begin(turnID: promptID.turnID, generation: generation) else {
            await client.cancel(sessionID: grokSessionID)
            throw CancellationError()
        }

        session.apply(.turnStarted)
        await save(session)
    }

    public nonisolated func cancelNow() {
        let stopped = handle.markCancelled()
        Task { await self.stopTurn(stopped) }
    }

    private func stopTurn(_ stopped: CodexTurnHandle.Stopped) async {
        if handle.generation == stopped.generation, handle.wasCancelled {
            for event in translation.finishInterruptedTurn() { await emit(event) }
            await filePendingAsks()
        }
        if handle.generation == stopped.generation, handle.wasCancelled,
           session.apply(.cancelled).moves { await save(session) }
        if handle.generation == stopped.generation, handle.wasCancelled, let grokSessionID {
            await client?.cancel(sessionID: grokSessionID)
        }
    }

    public nonisolated func terminateNow() {
        sink.noteProcessEnded()
        handle.markCancelled()
        connection.current?.terminateNow()
        Task { await self.shutdown() }
    }

    public func answer(requestID: String, decision: PermissionDecision) async {
        guard let ask = pending.take(requestID) else { return }
        let request = approvals[requestID]
        await write(answerTo: ask, decision: decision, request: request)
        await close(ask, as: decision.storedName, note: "")
        await grants.record(decision, from: ask)
    }

    public func shutdown() async {
        await filePendingAsks()
        if session.apply(.cancelled).moves { await save(session) }
        await dropConnection()
    }

    private func dropConnection() async {
        connectionGeneration += 1
        let closing = client
        let sessionToClose = grokSessionID
        client = nil
        grokSessionID = nil
        pumpTask?.cancel()
        pumpTask = nil
        handle.end()
        approvals.removeAll()
        for event in translation.finishInterruptedTurn() { await emit(event) }
        if let sessionToClose {
            await closing?.closeSession(sessionToClose)
        }
        await closing?.stop()
    }

    // MARK: - Connecting

    private func connected() async throws -> GrokClient {
        if let client {
            if client.isProcessAlive, await client.isClosed == false {
                return client
            }
            await dropConnection()
        }

        let stored = try? await store.setting(AgentCatalog.executablePathSettingKey(.grok))
        let client = makeClient(GrokClient.Configuration(
            executable: AgentCatalog.executable(for: .grok, override: stored),
            cwd: workspacePath,
            clientName: "Bloom",
            clientVersion: Self.clientVersion,
            model: wireModel,
            effort: session.effort,
            alwaysApprove: session.permissionMode == .bypassPermissions
        ))
        self.client = client
        permissionConnectionID = UUID()
        connection.attach(client)
        let events = client.events
        let generation = connectionGeneration
        pumpTask = Task { [weak self] in
            for await event in events {
                await self?.handle(event, from: generation)
            }
        }
        try await client.start()
        return client
    }

    private func openSession(on client: GrokClient) async throws -> String {
        if let grokSessionID { return grokSessionID }

        let servers = BridgeRegistration.grokServers(bridge)
        let opened: GrokSession
        if let stored = session.agentSessionID, !stored.isEmpty {
            do {
                opened = try await client.resumeSession(
                    stored,
                    cwd: workspacePath,
                    mcpServers: servers,
                    permissionMode: session.permissionMode
                )
            } catch {
                opened = try await client.newSession(
                    cwd: workspacePath,
                    mcpServers: servers,
                    permissionMode: session.permissionMode
                )
            }
        } else {
            opened = try await client.newSession(
                cwd: workspacePath,
                mcpServers: servers,
                permissionMode: session.permissionMode
            )
        }

        grokSessionID = opened.id
        translation.context.permissionMode = session.permissionMode.cliValue
        for event in translation.translate(.sessionReady(opened)) {
            await emit(event)
        }
        if session.agentSessionID != opened.id {
            session = session.with {
                $0.agentSessionID = opened.id
                $0.updatedAt = Date()
            }
            await save(session)
        }
        return opened.id
    }

    private func applyComposerSettings(on client: GrokClient, sessionID: String) async throws {
        let model = wireModel
        if !model.isEmpty {
            try await applyConfigOption(on: client, sessionID: sessionID, configID: "model", value: model)
            translation.context.model = model
        }
        if !session.effort.isEmpty {
            try await applyConfigOption(
                on: client,
                sessionID: sessionID,
                configID: "reasoning_effort",
                value: session.effort
            )
        }
    }

    /// A missing or rejected config option must not fail the turn. A dead connection must: that
    /// is the last RPC before the turn is marked running, and swallowing it left send hanging.
    private func applyConfigOption(
        on client: GrokClient,
        sessionID: String,
        configID: String,
        value: String
    ) async throws {
        do {
            try await client.setConfigOption(sessionID: sessionID, configID: configID, value: value)
        } catch let error as GrokClientError {
            switch error {
            case .connectionClosed, .notInitialized: throw error
            case .timedOut, .unexpectedResult: return
            }
        } catch {
            return
        }
    }

    // MARK: - Events

    private func handle(_ event: GrokEvent, from generation: UInt64) async {
        guard generation == connectionGeneration else { return }

        if case .closed = event, handle.wasCancelled || trouble.hasStopped { return }

        if case .permission(let request) = event {
            if handle.wasCancelled {
                await client?.answer(request.id, with: GrokPermission.cancelledResult)
                return
            }
            await ask(request)
            return
        }

        if case .update = event, handle.wasCancelled { return }

        let ending = if case .promptCompleted(let result) = event { result.requestID.turnID } else { nil as String? }
        if let ending, !handle.acceptsTerminal(turnID: ending) { return }

        for translated in translation.translate(event) {
            await emit(translated, endingTurn: ending)
        }
    }

    private func emit(_ event: AgentEvent, endingTurn: String? = nil) async {
        let intent = handle.intent
        var storedMessage: Message?
        if event.isTranscriptRow {
            storedMessage = await persist(
                kind: event.kind,
                payload: event.raw.isEmpty ? Data("{}".utf8) : event.raw,
                refID: event.refID
            )
        }

        if let endingTurn, !handle.acceptsTerminal(turnID: endingTurn, intent: intent) { return }

        switch event {
        case .result(let result):
            handle.end()
            session.apply(.turnFinished(isError: result.isError))
            session = session.with {
                $0.inputTokens += result.usage.inputTokens
                $0.outputTokens += result.usage.outputTokens
                if result.usage.contextTokens > 0 { $0.contextTokens = result.usage.contextTokens }
            }
            await save(session)

        case .error:
            handle.end()
            session.apply(.turnFinished(isError: true))
            await save(session)

        default:
            break
        }

        if let endingTurn, !handle.acceptsTerminal(turnID: endingTurn, intent: intent) { return }
        sink.yield(event, messageSeq: storedMessage?.seq)
    }

    // MARK: - Asking

    private func ask(_ request: GrokPermissionRequest) async {
        let ask = GrokPermission.ask(for: request, connectionID: permissionConnectionID)
        pending.add(ask)
        approvals[ask.requestID] = request

        do {
            try await store.appendPermissionAsk(sessionID: session.id, ask: ask)
        } catch {
            await report("could not store a permission question", error)
        }
        await persist(kind: .permissionAsk, payload: ask.raw, refID: ask.toolUseID)
        sink.yield(.permissionAsk(ask))

        let matched = await grants.matching(ask)
        if let matched, let claimed = pending.take(ask.requestID) {
            await write(answerTo: claimed, decision: .allow(scope: .session), request: request)
            await close(claimed, as: PermissionAskOutcome.auto, note: PermissionGrantIndex.note(for: matched))
            await grants.recordUse(of: matched)
            return
        }

        guard matched == nil, pending.contains(ask.requestID) else { return }
        session.apply(.blocked)
        await save(session)
    }

    /// Stop and quit answer pending asks as ACP `cancelled`, not `reject_always`. The latter can
    /// persist a deny in Grok's session for a tool the user only meant to interrupt.
    private func filePendingAsks() async {
        for ask in pending.drain() {
            if let request = approvals[ask.requestID] {
                await client?.answer(request.id, with: GrokPermission.cancelledResult)
            }
            await close(ask, as: PermissionAskOutcome.stopped, note: "")
        }
        if session.apply(.unblocked).moves { await save(session) }
    }

    private func write(
        answerTo ask: PermissionAsk,
        decision: PermissionDecision,
        request: GrokPermissionRequest?
    ) async {
        if let request {
            if let optionID = GrokPermission.optionID(for: decision, in: request) {
                await client?.answer(request.id, with: GrokPermission.selectedResult(optionID: optionID))
            } else {
                await client?.answer(request.id, with: GrokPermission.cancelledResult)
            }
        }
        approvals[ask.requestID] = nil
        guard pending.isEmpty else { return }
        guard session.apply(.unblocked).moves else { return }
        await save(session)
    }

    private func close(_ ask: PermissionAsk, as decision: String, note: String) async {
        pending.remove(ask.requestID)
        approvals[ask.requestID] = nil
        do {
            try await store.resolvePermissionAsk(id: ask.requestID, decision: decision)
        } catch {
            await report("could not record a permission decision", error)
        }
        sink.yield(.permissionDecided(PermissionResolution(
            requestID: ask.requestID,
            toolUseID: ask.toolUseID,
            decision: decision,
            note: note
        )))
    }

    // MARK: - Storage

    static func userPayload(_ text: String) -> Data {
        let json = JSONValue.object([
            "type": .string("user"),
            "message": .object([
                "role": .string("user"),
                "content": .array([.object([
                    "type": .string("text"),
                    "text": .string(text),
                ])]),
            ]),
        ])
        return Data(json.compactJSON.utf8)
    }

    @discardableResult
    private func persist(kind: MessageKind, payload: Data, refID: String? = nil) async -> Message? {
        do {
            return try await store.appendNext(
                sessionID: session.id,
                kind: kind,
                payload: payload,
                refID: refID
            )
        } catch {
            await report("could not store a \(kind.rawValue) row", error)
            return nil
        }
    }

    private func save(_ session: Session) async {
        do {
            try await store.update(sessionID: session.id) {
                $0.agentSessionID = session.agentSessionID
                $0.state = session.state
                $0.inputTokens = session.inputTokens
                $0.outputTokens = session.outputTokens
                $0.contextTokens = session.contextTokens
                $0.updatedAt = session.updatedAt
            }
        } catch {
            await report("could not save the session", error)
        }
    }

    private func report(_ what: String, _ error: Error) async {
        Self.log.error("\(what, privacy: .public): \(error.readableMessage, privacy: .public)")

        let standing = await TranscriptStanding.of(sessionID: session.id, in: store)
        switch trouble.record(WorkspaceTrouble.recording(
            transcript: standing, complaint: TranscriptStanding.complaint(about: error)
        )) {
        case .tell(let sentence):
            sink.yield(.error(.storage(message: sentence)))
        case .stop:
            Self.log.info("the transcript for \(self.session.id.rawValue, privacy: .public) has been removed, so this run is being stopped without a word")
            terminateNow()
        case .alreadyStopped:
            break
        }
    }

    var transcriptWasRemoved: Bool { trouble.hasStopped }

    private static let log = CoreLogger(
        subsystem: Bundle.main.bundleIdentifier ?? "be.spatie.bloom",
        category: "grok-runner"
    )
}

private final class LiveConnection: Sendable {
    private let client = Mutex<GrokClient?>(nil)

    var current: GrokClient? { client.withLock { $0 } }

    func attach(_ client: GrokClient) {
        self.client.withLock { $0 = client }
    }
}
