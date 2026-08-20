import Foundation

/// Supervises one `codex app-server` connection for one Bloom chat.
///
/// The shape is `AgentRunner`'s, deliberately: a long-lived process, the thread id persisted the
/// moment it arrives so a crashed app can resume, every event written to the store before it
/// reaches the UI, and the same permission bookkeeping. What it is not is a second code path
/// inside `AgentRunner`. The two backends share no protocol, only the idea of a conversation, and
/// that idea is `SessionRunner`.
///
/// **One connection per chat.** app-server can carry several threads on one connection, which is
/// tempting to share per workspace or per app, and would mean one crash taking down every Codex
/// chat at once. The per-chat lifetime already matches what the workspace manages.
public actor CodexRunner: SessionRunner {
    public nonisolated let agentKind = AgentKind.codex
    public nonisolated let workspacePath: String
    public nonisolated let sessionID: String

    private let store: Store
    private let makeClient: @Sendable (CodexClient.Configuration) -> CodexClient

    private var session: Session
    private var client: CodexClient?
    private var pumpTask: Task<Void, Never>?
    private var translation: CodexTranslation
    private var threadID: String?
    private var cancelled = false
    private var cachedRepoID: String?

    /// The items seen this turn, by id.
    ///
    /// An approval request carries only an item id: the diff or the command is on the
    /// `item/started` that arrived a moment before it. Without this the question would have to be
    /// asked with nothing on it.
    private var items: [String: CodexItem] = [:]

    /// Which server request each pending ask answers. Kept apart from the ask itself because the
    /// id is the server's own numbering and means nothing outside this connection, while the ask
    /// is written to a database that outlives it.
    private var approvals: [String: CodexApprovalRequest] = [:]

    private let pending = PendingCodexAsks()
    private let handle = TurnHandle()
    private let sink = EventFanout<AgentEvent>()

    private var persistenceFailures = 0
    private var lastFailure: String?

    public init(
        workspacePath: String,
        session: Session,
        store: Store,
        makeClient: @escaping @Sendable (CodexClient.Configuration) -> CodexClient = CodexRunner.spawn
    ) {
        self.workspacePath = workspacePath
        self.sessionID = session.id
        self.session = session
        self.store = store
        self.makeClient = makeClient
        self.translation = CodexTranslation(context: CodexTranslation.Context(
            model: session.model,
            cwd: workspacePath,
            permissionMode: session.permissionMode.rawValue
        ))
    }

    public static let spawn: @Sendable (CodexClient.Configuration) -> CodexClient = { configuration in
        CodexClient(configuration: configuration)
    }

    // MARK: - SessionRunner

    public nonisolated var events: AsyncStream<AgentEvent> { sink.stream() }

    public var isRunning: Bool { handle.isLive }

    public var currentSession: Session { session }

    public var lastPersistenceFailure: String? { lastFailure }

    public var persistenceFailureCount: Int { persistenceFailures }

    /// Write one user turn. Connects, and starts or resumes the thread, on first use.
    ///
    /// Model, effort, approval policy and sandbox all travel **with the turn** rather than with
    /// the process, which is what makes changing a composer chip mid chat take effect on the next
    /// turn without restarting anything. Claude Code cannot do that: its equivalents are argv.
    public func send(_ text: String) async throws {
        let client = try await connected()
        let threadID = try await openThread(on: client)

        cancelled = false
        await persist(kind: .user, payload: Self.userPayload(text))

        let turn = try await client.startTurn(
            threadID: threadID,
            input: [.text(text)],
            model: session.model,
            effort: session.effort,
            approvalPolicy: Self.approvalPolicy(for: session.permissionMode),
            sandboxPolicy: Self.sandboxPolicy(for: session.permissionMode, writableRoot: workspacePath)
        )
        handle.begin(turnID: turn.id)

        session = session.with {
            $0.state = .running
            $0.updatedAt = Date()
        }
        await save(session)
    }

    /// Stop the turn that is running.
    ///
    /// Interrupting is an RPC here rather than a signal, so unlike the Claude Code side there is
    /// nothing synchronous to do: the intent is recorded now, which is what stops a late result
    /// being filed as a success, and the request goes out on the next turn of the actor.
    public nonisolated func cancelNow() {
        handle.markCancelled()
        Task { await self.interrupt() }
    }

    private func interrupt() async {
        cancelled = true
        guard let client, let threadID, let turnID = handle.turnID else { return }
        try? await client.interruptTurn(threadID: threadID, turnID: turnID)
    }

    /// Answer one question, as a person. The turn resumes on the other side of this line.
    public func answer(requestID: String, decision: PermissionDecision) async {
        guard let ask = pending.take(requestID) else { return }
        await write(answerTo: ask, decision: CodexPermission.decision(for: decision))
        await deliverReason(of: decision)
        await close(ask, as: decision.storedName, note: "")

        // Bloom's own bookkeeping, and it happens after the agent has been unblocked, so a
        // database that refuses the write cannot leave a turn hanging on a question that was
        // already answered.
        if case .allow(.project) = decision, let repoID = await repoID() {
            for rule in ask.rules {
                _ = try? await store.upsert(PermissionGrant.granting(rule, repoID: repoID, for: ask.subject))
            }
        }
    }

    /// Ends the connection and the pump. The chat can be sent to again afterwards: the thread id
    /// is stored, so the next turn resumes rather than starting a new conversation.
    public func shutdown() async {
        for ask in pending.drain() {
            await write(answerTo: ask, decision: .decline)
            await close(ask, as: PermissionAskOutcome.abandoned, note: "")
        }
        await client?.stop()
        client = nil
        pumpTask?.cancel()
        pumpTask = nil
        handle.end()
    }

    // MARK: - Connecting

    private func connected() async throws -> CodexClient {
        if let client { return client }

        let client = makeClient(CodexClient.Configuration(
            cwd: workspacePath,
            clientName: "Bloom",
            clientVersion: Self.clientVersion
        ))
        self.client = client
        // Attached before the handshake, so nothing the server says between connecting and the
        // first turn can arrive with nowhere to go.
        let events = client.events
        pumpTask = Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
        }
        try await client.start()
        return client
    }

    /// The thread this chat is, started or resumed.
    ///
    /// The id is written to the session row the moment it exists, which is what makes a chat
    /// survive a crash: `agent_session_id` holds a Codex thread id exactly as it holds a Claude
    /// session id, and it means the same thing.
    private func openThread(on client: CodexClient) async throws -> String {
        if let threadID { return threadID }

        let sandbox = Self.sandboxMode(for: session.permissionMode)
        let handle: CodexThreadHandle
        if let stored = session.agentSessionID, !stored.isEmpty {
            handle = try await client.resumeThread(stored, cwd: workspacePath, sandbox: sandbox)
        } else {
            handle = try await client.startThread(
                cwd: workspacePath,
                model: session.model,
                approvalPolicy: Self.approvalPolicy(for: session.permissionMode),
                sandbox: sandbox
            )
        }

        threadID = handle.id
        if session.agentSessionID != handle.id {
            session = session.with {
                $0.agentSessionID = handle.id
                $0.updatedAt = Date()
            }
            await save(session)
        }
        return handle.id
    }

    static let clientVersion = "1.0"

    // MARK: - Permission policy

    /// How Bloom's four modes reach a protocol that has no modes.
    ///
    /// Codex crosses an approval policy with a sandbox, and the grid does not line up with the
    /// picker: `plan` has no equivalent at all and must not be offered for a Codex chat, and Ask
    /// and Accept edits differ only in how much the sandbox lets through without a question.
    public static func approvalPolicy(for mode: PermissionMode) -> CodexApprovalPolicy {
        switch mode {
        case .bypassPermissions: .never
        // `untrusted` asks about nearly everything, including reads, which is a mode nobody leaves
        // on. `on-request` is the one that asks about what the sandbox refused.
        case .auto, .acceptEdits, .plan: .onRequest
        }
    }

    public static func sandboxMode(for mode: PermissionMode) -> CodexSandboxMode {
        switch mode {
        case .bypassPermissions: .dangerFullAccess
        case .acceptEdits: .workspaceWrite
        // Ask and Plan both mean "do not write without telling me". Read-only is the sandbox that
        // means it, and a write then arrives as a question rather than as a fact.
        case .auto, .plan: .readOnly
        }
    }

    /// The per-turn form, which is a different type to the per-thread one with the same meanings
    /// spelled differently. `workspaceWrite` names the worktree as its writable root, so a Codex
    /// chat can write where its own workspace is and nowhere else.
    public static func sandboxPolicy(for mode: PermissionMode, writableRoot: String) -> JSONValue {
        switch sandboxMode(for: mode) {
        case .readOnly:
            return .object(["type": .string("readOnly")])
        case .dangerFullAccess:
            return .object(["type": .string("dangerFullAccess")])
        case .workspaceWrite:
            return .object([
                "type": .string("workspaceWrite"),
                "writableRoots": .array([.string(writableRoot)]),
                "networkAccess": .bool(false),
            ])
        }
    }

    // MARK: - Events

    private func handle(_ event: CodexEvent) async {
        remember(event)

        if case .approval(let request) = event {
            await ask(request)
            return
        }

        for translated in translation.translate(event) {
            await emit(translated)
        }
    }

    /// Keep the items a question might be about, and forget them when the turn that made them ends.
    private func remember(_ event: CodexEvent) {
        switch event {
        case .itemStarted(let started), .itemCompleted(let started):
            items[started.item.id] = started.item
        case .turnCompleted:
            items.removeAll()
        default:
            break
        }
    }

    private func emit(_ event: AgentEvent) async {
        if event.isTranscriptRow {
            await persist(
                kind: event.kind,
                payload: event.raw.isEmpty ? Data("{}".utf8) : event.raw,
                refID: event.refID
            )
        }

        switch event {
        case .result(let result):
            handle.end()
            session = session.with {
                $0.inputTokens += result.usage.inputTokens
                $0.outputTokens += result.usage.outputTokens
                // No price reaches this protocol, so `costUSD` is deliberately never touched: a
                // number that means "we do not know" must not be added to one that means dollars.
                if result.usage.contextTokens > 0 { $0.contextTokens = result.usage.contextTokens }
                $0.state = cancelled ? .cancelled : (result.isError ? .failed : .idle)
                $0.updatedAt = Date()
            }
            await save(session)

        case .error:
            handle.end()
            session = session.with {
                $0.state = cancelled ? .cancelled : .failed
                $0.updatedAt = Date()
            }
            await save(session)

        default:
            break
        }

        sink.yield(event)
    }

    // MARK: - Asking

    private func ask(_ request: CodexApprovalRequest) async {
        let ask = CodexPermission.ask(for: request, item: items[request.itemID])
        pending.add(ask)
        approvals[ask.requestID] = request

        do {
            try await store.appendPermissionAsk(sessionID: session.id, ask: ask)
        } catch {
            report("Could not store a permission question", error)
        }
        await persist(kind: .permissionAsk, payload: ask.raw, refID: ask.toolUseID)

        // Yielded before the grant lookup, exactly as the Claude Code side does it: a question a
        // stored rule answers is decided in the same breath it arrives, and a decision reaching a
        // view before the question it decides leaves the view with no row to settle.
        sink.yield(.permissionAsk(ask))

        let grants = await matchingGrants(for: ask)
        if let grants, let claimed = pending.take(ask.requestID) {
            await write(answerTo: claimed, decision: .acceptForSession)
            await close(claimed, as: PermissionAskOutcome.auto, note: PermissionGrantIndex.note(for: grants))
            for grant in grants {
                try? await store.recordPermissionGrantUse(id: grant.id)
            }
            return
        }

        guard grants == nil, pending.contains(ask.requestID) else { return }

        session = session.with {
            $0.state = .waiting
            $0.updatedAt = Date()
        }
        await save(session)
    }

    private func matchingGrants(for ask: PermissionAsk) async -> [PermissionGrant]? {
        guard ask.canWiden, let repoID = await repoID() else { return nil }
        guard let grants = try? await store.permissionGrants(repoID: repoID) else { return nil }
        return PermissionGrantIndex.match(ask: ask, grants: grants)
    }

    /// Say why, in the only place this protocol has room for it.
    ///
    /// An approval is answered with a word: `accept`, `decline`, `cancel`. There is no field for
    /// the sentence a person typed, and no field for the sentence Bloom sends by default either,
    /// so on this backend a refusal arrives at the model as a bare no. Measured against the real
    /// server, that is not enough: after a declined patch the agent tried the same patch again
    /// immediately, twice.
    ///
    /// `turn/steer` is the room. It puts words into the turn that is already running, and the same
    /// measurement showed the agent reading them and doing the different thing that was asked for.
    /// So the reason goes out right behind the refusal, and a Codex denial says as much as a
    /// Claude Code one.
    ///
    /// Failure here is deliberately quiet. The refusal has already landed and the turn is already
    /// unblocked; a steer that misses because the turn moved on must not turn an answered question
    /// into an error.
    private func deliverReason(of decision: PermissionDecision) async {
        guard case .deny(let message, let endsTurn) = decision, !endsTurn else { return }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let client, let threadID, let turnID = handle.turnID else { return }
        _ = try? await client.steerTurn(threadID: threadID, turnID: turnID, input: [.text(text)])
    }

    private func write(answerTo ask: PermissionAsk, decision: CodexApprovalDecision) async {
        if let request = approvals.removeValue(forKey: ask.requestID) {
            await client?.answer(request, decision: decision)
        }

        guard pending.isEmpty, session.state == .waiting else { return }
        session = session.with {
            $0.state = .running
            $0.updatedAt = Date()
        }
        await save(session)
    }

    private func close(_ ask: PermissionAsk, as decision: String, note: String) async {
        pending.remove(ask.requestID)
        approvals[ask.requestID] = nil
        do {
            try await store.resolvePermissionAsk(id: ask.requestID, decision: decision)
        } catch {
            report("Could not record a permission decision", error)
        }
        sink.yield(.permissionDecided(PermissionResolution(
            requestID: ask.requestID,
            toolUseID: ask.toolUseID,
            decision: decision,
            note: note
        )))
    }

    private func repoID() async -> String? {
        if let cachedRepoID { return cachedRepoID }
        guard let workspace = try? await store.workspace(id: session.workspaceID) else { return nil }
        cachedRepoID = workspace.repoID
        return workspace.repoID
    }

    // MARK: - Storage

    static func userPayload(_ text: String) -> Data {
        // The shape the transcript already draws a user row from, so a Codex prompt and a Claude
        // one are the same row in the same table read by the same code.
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

    private func persist(kind: MessageKind, payload: Data, refID: String? = nil) async {
        do {
            try await store.appendNext(
                sessionID: session.id,
                kind: kind,
                payload: payload,
                refID: refID
            )
        } catch {
            report("Could not store a \(kind.rawValue) row", error)
        }
    }

    /// Writes the columns this runner owns, and nothing else. The same rule as `AgentRunner`: a
    /// whole-value write would put back a title, a model or a read mark from whenever this runner
    /// last read the row.
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
            report("Could not save the session", error)
        }
    }

    private func report(_ what: String, _ error: Error) {
        persistenceFailures += 1
        lastFailure = "\(what): \(error.readableMessage)"
    }
}

// MARK: - Turn handle

/// What a turn is, from outside the actor.
///
/// Stop is pressed from synchronous main-actor code, and the actor at that moment is busy running
/// the thing being stopped. The intent has to be recorded where it can be read without waiting.
private final class TurnHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var current: String?
    private var cancelled = false

    var turnID: String? {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    var isLive: Bool {
        lock.lock(); defer { lock.unlock() }
        return current != nil
    }

    var wasCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func begin(turnID: String) {
        lock.lock(); defer { lock.unlock() }
        current = turnID
        cancelled = false
    }

    func markCancelled() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }

    func end() {
        lock.lock(); defer { lock.unlock() }
        current = nil
    }
}

/// The questions this chat is holding a turn open for. Identical in shape to the Claude Code
/// side's, and separate because claiming one has to be atomic: a person answering while a stored
/// grant is being looked up must not produce two answers to one request.
private final class PendingCodexAsks: @unchecked Sendable {
    private let lock = NSLock()
    private var asks: [PermissionAsk] = []

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return asks.isEmpty
    }

    func add(_ ask: PermissionAsk) {
        lock.lock(); defer { lock.unlock() }
        guard !asks.contains(where: { $0.requestID == ask.requestID }) else { return }
        asks.append(ask)
    }

    func take(_ requestID: String) -> PermissionAsk? {
        lock.lock(); defer { lock.unlock() }
        guard let index = asks.firstIndex(where: { $0.requestID == requestID }) else { return nil }
        return asks.remove(at: index)
    }

    func contains(_ requestID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return asks.contains { $0.requestID == requestID }
    }

    func remove(_ requestID: String) {
        lock.lock(); defer { lock.unlock() }
        asks.removeAll { $0.requestID == requestID }
    }

    func drain() -> [PermissionAsk] {
        lock.lock(); defer { lock.unlock() }
        let all = asks
        asks = []
        return all
    }
}
