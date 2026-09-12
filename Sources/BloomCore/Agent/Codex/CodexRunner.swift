import Foundation
import Synchronization

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
    public nonisolated let sessionID: SessionID

    private let store: Store
    private let makeClient: @Sendable (CodexClient.Configuration) -> CodexClient

    private var session: Session
    private var client: CodexClient?
    private var pumpTask: Task<Void, Never>?
    private var translation: CodexTranslation
    private var threadID: String?
    private var isRewinding = false
    private var planningRescanToken: String?

    /// What this project has already approved. One type for both backends: see `SessionGrants`.
    private let grants: SessionGrants

    /// How large this chat's server was told the context window is, and therefore what the live
    /// connection was launched with. See `applyContextWindowChange`.
    private var contextWindow = CodexContextWindow.modelDefault

    /// The model id this chat's row means, which is not always the string it holds: a row written
    /// from a settings file can carry the backend in front of the id, and `codex:gpt-5.6-sol` is
    /// not something the server accepts. `ModelAlias.cliValue` is the same guard on the other
    /// backend, and `ModelIdentifier`'s head is the bug both were added for.
    private var wireModel: String { ModelIdentifier.resolve(session.model).model }

    /// Items seen in each thread, keyed by thread and then item id.
    ///
    /// An approval request carries only an item id: the diff or the command is on the
    /// `item/started` that arrived a moment before it. Without this the question would have to be
    /// asked with nothing on it.
    private var items: [String: [String: CodexItem]] = [:]

    /// Which server request each pending ask answers. Kept apart from the ask itself because the
    /// id is the server's own numbering and means nothing outside this connection, while the ask
    /// is written to a database that outlives it.
    private var approvals: [String: CodexApprovalRequest] = [:]
    private var connectionID = UUID()

    /// The live connection, held outside the actor so quit, close and archive can signal the
    /// server without waiting for a turn on one. Attached on every connect and never cleared, for
    /// the reason `LiveProcess` in `CodexClient` gives: a box emptied by the bookkeeping running
    /// behind the signal would answer "gone" for a process that was still dying.
    private let connection = LiveConnection()

    private let pending = PendingAsks()
    private let handle = CodexTurnHandle()
    private let sink = AgentPresentationFeed()
    private var sendsInFlight = 0
    private var wasEvicted = false

    /// Whether this run has already been stopped because its transcript was deleted underneath
    /// it. See `stopBecauseTheTranscriptWentAway`.
    /// What the store has refused, and whether the transcript has gone. The same type the Claude
    /// Code side keeps, because the rule was the same and was written twice: `PersistenceTrouble`.
    private var trouble = PersistenceTrouble()

    /// The workspace bridge this chat registers, or nil for none. Written once, by whoever built
    /// this runner, and read on every connect: `CodexClient.Configuration` is rebuilt per connect
    /// exactly as `AgentRunner`'s argv is recomputed per start, so the two backends re-register on
    /// the same schedule.
    private let bridge: BridgeAttachment?

    public init(
        workspacePath: String,
        session: Session,
        store: Store,
        bridge: BridgeAttachment? = nil,
        makeClient: @escaping @Sendable (CodexClient.Configuration) -> CodexClient = CodexRunner.spawn
    ) {
        self.workspacePath = workspacePath
        self.sessionID = session.id
        self.session = session
        self.store = store
        self.bridge = bridge
        self.makeClient = makeClient
        self.grants = SessionGrants(store: store, workspaceID: session.workspaceID)
        self.translation = CodexTranslation(context: CodexTranslation.Context(
            model: ModelIdentifier.resolve(session.model).model,
            cwd: workspacePath,
            permissionMode: session.permissionMode.rawValue
        ))
    }

    public static let spawn: @Sendable (CodexClient.Configuration) -> CodexClient = { configuration in
        CodexClient(configuration: configuration)
    }

    // MARK: - SessionRunner

    public nonisolated var events: AsyncStream<AgentEvent> { sink.stream() }
    public nonisolated var presentationFeed: AgentPresentationFeed? { sink }

    /// Whether the server process is still there, which on this backend is **not** whether a turn
    /// is running.
    ///
    /// The two are one fact for Claude Code, whose process is killed by Stop and started again by
    /// the next turn, and two facts here: `codex app-server` is long lived by design and outlives
    /// every turn on it. A quit path polling "is a turn open" watched the interrupt land, saw the
    /// turn close and concluded the process was gone. It was not. It had never been signalled.
    public var isProcessAlive: Bool { connection.current?.isProcessAlive ?? false }

    public var currentSession: Session { session }

    public var lastPersistenceFailure: String? { trouble.lastSentence }

    public var persistenceFailureCount: Int { trouble.failures }

    /// Write one turn. Connects, and starts or resumes the thread, on first use.
    ///
    /// `recording` is the row to write down in place of the user row, for a turn another agent
    /// asked for: see `SessionRunner.send(_:recording:)` for why what goes out and what is drawn
    /// are not the same string.
    ///
    /// Model, effort, approval policy and sandbox all travel **with the turn** rather than with
    /// the process, which is what makes changing a composer chip mid chat take effect on the next
    /// turn without restarting anything. Claude Code cannot do that: its equivalents are argv.
    ///
    /// **A turn that is already open takes the words instead of a second turn beside it.** This
    /// backend has a call for exactly that, `turn/steer`, and what `turn/start` does to a thread
    /// with an open turn is not measured, so it is not the thing to find out with somebody's
    /// sentence. See `AgentKind.acceptsMidTurnMessage` for why a message reaches here mid turn at
    /// all, and `steer(_:threadID:turnID:on:)` for the fall back when the turn has just ended.
    public func send(_ text: String, recording: Data? = nil) async throws {
        try await send(text, recording: recording, deliveryID: nil, interactionMode: nil)
    }

    public func evictIfIdle(for duration: Duration) async -> Bool {
        guard !wasEvicted, !isRewinding, sendsInFlight == 0, !session.state.isMidTurn,
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
        var mode = delivery.interactionMode
        if mode == nil { mode = try await store.session(id: sessionID)?.interactionMode }
        try await send(delivery.sent, recording: delivery.crewPayload,
                       deliveryID: delivery.id, interactionMode: mode)
    }

    private func send(_ text: String, recording: Data?, deliveryID: DeliveryID?,
                      interactionMode: InteractionMode?) async throws {
        guard !wasEvicted else { throw ProviderIdleError.retired }
        guard !isRewinding else { throw ConversationRewindError.busy }
        sendsInFlight += 1
        sink.noteActivity()
        defer { sendsInFlight -= 1 }
        let generation = handle.generation
        let replacement = handle.prepareReplacement()
        defer { handle.finishReplacement(replacement) }
        let prompt = try await store.sideConversationTurn(text, sessionID: sessionID)
        await applyContextWindowChange()
        let token = try await store.setting(CodexPlanningCapability.rescanKey)
        if token != planningRescanToken, handle.turnID == nil {
            // After updating the CLI, discovery must use the new executable rather than the
            // old app-server process that intentionally survives between turns.
            await dropConnection()
            planningRescanToken = token
        }
        try handle.check(generation)
        let client = try await connected()
        try handle.check(generation)
        let threadID = try await openThread(on: client)
        try handle.check(generation)
        // One row, whichever it is, for the reason `AgentRunner.send` gives: the crew payload
        // already holds both renderings, and a user row beside it is the envelope back on screen.
        if deliveryID == nil {
            if let recording { await persist(kind: .crew, payload: recording) } else { await persist(kind: .user, payload: Self.userPayload(text)) }
        }
        try handle.check(generation)

        // Absorbed into the running turn, so there is no new turn id to hold and no state to
        // move: `turnStarted` is `unchanged` from `running` anyway. See `SessionLifecycle`.
        //
        // `steerableTurnID` rather than `turnID`, and the difference is a turn somebody stopped.
        // Asked rather than left to the steer failing, because a state has to be guarded by asking:
        // a turn the server has been told to abandon is not a turn a message belongs in, whatever
        // the server answers about it.
        if let deliveryID { try await store.beginDeliveryDispatch(id: deliveryID) }
        if let turnID = handle.steerableTurnID,
           try await steer(prompt, threadID: threadID, turnID: turnID, on: client) {
            if let deliveryID { try await store.acceptDelivery(id: deliveryID, providerTurnID: turnID) }
            return
        }
        try handle.check(generation)

        let turn: CodexTurn
        do {
            turn = try await client.startTurn(
                threadID: threadID,
                input: [.text(prompt)],
                model: wireModel,
                effort: session.effort,
                approvalPolicy: Self.approvalPolicy(for: session.permissionMode),
                sandboxPolicy: Self.sandboxPolicy(for: session.permissionMode, writableRoot: workspacePath),
                approvalsReviewer: Self.approvalsReviewer(for: session.permissionMode),
                interactionMode: interactionMode ?? session.interactionMode
            )
        } catch {
            if await client.planningIsSupported == false {
                try? await store.setSetting(CodexPlanningCapability.unavailableKey, "1")
            }
            if let deliveryID, InteractionModeFailure.isDefinitiveTurnRejection(error) {
                try await store.restoreDelivery(id: deliveryID)
            }
            throw error
        }
        if await client.planningIsSupported == false {
            try? await store.setSetting(CodexPlanningCapability.unavailableKey, "1")
        }
        if let deliveryID { try await store.acceptDelivery(id: deliveryID, providerTurnID: turn.id) }
        guard handle.begin(turnID: turn.id, generation: generation) else {
            // Stop can arrive while turn/start is in flight, before there is an id to interrupt.
            // Do not resurrect that turn when the reply finally supplies its id.
            try? await client.interruptTurn(threadID: threadID, turnID: turn.id)
            throw CancellationError()
        }

        session.apply(.turnStarted)
        await save(session)
        if prompt != text {
            // startTurn succeeded. A rejection leaves the context available for the next retry.
            try? await store.acknowledgeSideConversationContext(sessionID: sessionID)
        }
    }

    /// Stop the turn that is running, and leave the server where it is.
    ///
    /// Interrupting is an RPC here rather than a signal, so unlike the Claude Code side there is
    /// nothing synchronous to do: the intent is recorded now, which is what stops a late result
    /// being filed as a success, and the request goes out on the next turn of the actor.
    ///
    /// **Not a kill, deliberately.** Claude Code's Stop has to kill its process because that is
    /// the only way to stop a turn there, and the next turn spawns another one with `--resume`.
    /// Killing here would cost something Claude Code has not got: the grants a person gave with
    /// "allow for this session" live in the app-server process rather than in Bloom's database,
    /// so every Stop would quietly throw them away and make the next turn ask again. What kills
    /// the server is `terminateNow`, and the difference between the two is which of them a chat
    /// is expected to survive.
    public nonisolated func cancelNow() {
        let stopped = handle.markCancelled()
        let children = childTurns.snapshot
        Task { await self.stopTurn(stopped, children: children) }
    }

    /// Stop, as the button means it: file the questions and then interrupt the turn.
    ///
    /// **This used to interrupt and nothing else.** `shutdown` already drained the pending asks
    /// and wrote down why, and Stop is the other half of the same moment: a question left pending
    /// keeps its buttons on a row nobody can answer any more, and the next launch's sweep files it
    /// as "Bloom was not running when this was asked", which is untrue and is not what the person
    /// saw. The Claude Code side has answered them on this path all along, which is why the two
    /// backends disagreed about what Stop did.
    ///
    /// Answered before the interrupt rather than after, for the reason `AgentRunner.cancelNow`
    /// gives: an answer written after the thing that closes the turn is an answer the model never
    /// receives.
    private func stopTurn(_ stopped: CodexTurnHandle.Stopped, children: [String: String]) async {
        let connection = client
        async let family: Void = CodexFamilyStop.interrupt(children) { thread, turn, timeout in
            try? await connection?.interruptTurn(threadID: thread, turnID: turn, timeout: timeout)
        }
        if handle.generation == stopped.generation, handle.wasCancelled {
            await filePendingAsks()
        }
        await interrupt(stopped)
        await family
    }

    /// Answers every question this turn can no longer answer, and files it as stopped.
    ///
    /// One copy, called from `stopTurn` and from `shutdown`. They are the same event seen from two
    /// distances (the turn ended, the chat ended) and they were two pieces of code, one of which
    /// was missing.
    private func filePendingAsks() async {
        for ask in pending.drain() {
            await write(answerTo: ask, decision: .decline)
            await close(ask, as: PermissionAskOutcome.stopped, note: "")
        }
    }

    /// The chat is going away: quit, close, or the worktree being archived. Kill the server.
    ///
    /// **The orphaned-children bug, on the newer backend.** Nothing in this file used to signal
    /// the process at all. `cancelNow` sent an interrupt and returned, `CodexClient.stop` had no
    /// caller, and the quit path then polled a flag that means "a turn is open", watched the
    /// interrupt close the turn and reported success. Measured against the real binary: at the
    /// moment Bloom concluded the agent was gone, `codex app-server` and the app-server binary
    /// that node forks were both still running, and still running five seconds later. On quit
    /// they were reparented to launchd along with anything a turn had spawned; on archive they
    /// kept their working directory inside a worktree `git worktree remove --force` was about to
    /// delete, which is what `performArchive` tears the agents down first to prevent.
    ///
    /// Synchronous for the same reason `AgentRunner.cancelNow` is: quit and archive run on the
    /// main actor and cannot wait for a turn on an actor that is busy running the thing being
    /// ended. Everything that cannot be done in a signal is done in `shutdown` behind it.
    public nonisolated func terminateNow() {
        handle.markCancelled()
        connection.current?.terminateNow()
        Task { await self.shutdown() }
    }

    private func interrupt(_ stopped: CodexTurnHandle.Stopped) async {
        // Capture the stopped turn before persistence suspends. A new explicit send may install
        // a different turn while the cancelled state is being saved; that turn is not this Stop's.
        let target = stopped.turnID
        let client = self.client
        let threadID = self.threadID
        // Written here rather than left for the result to infer, which is what the `cancelled`
        // flag used to do at both of the sites below. `SessionLifecycle` refuses a stop on a
        // session with no turn open and ignores a result on one that has already been stopped, so
        // the two facts are stated once each instead of being recombined by a ternary twice.
        if handle.generation == stopped.generation, handle.wasCancelled,
           session.apply(.cancelled).moves { await save(session) }
        guard let client, let threadID, let target else { return }
        do { try await client.interruptTurn(threadID: threadID, turnID: target, timeout: .seconds(3)) } catch { client.terminateNow() }
    }

    /// Answer one question, as a person. The turn resumes on the other side of this line.
    public func answer(requestID: String, decision: PermissionDecision) async {
        guard let ask = pending.take(requestID) else { return }
        let request = approvals[requestID]
        let answerInput: JSONValue?
        if case .answer(let input) = decision { answerInput = input } else { answerInput = nil }
        await write(answerTo: ask, decision: CodexPermission.decision(for: decision), answerInput: answerInput)
        await deliverReason(of: decision, request: request)
        await close(ask, as: decision.storedName, note: "")

        // Bloom's own bookkeeping, and it happens after the agent has been unblocked, so a
        // database that refuses the write cannot leave a turn hanging on a question that was
        // already answered. See `SessionGrants.record`.
        await grants.record(decision, from: ask)
    }

    /// Ends the connection and the pump, and files every question that can now never be answered.
    ///
    /// Reached from `terminateNow`, which has already signalled the process, so none of the words
    /// written here reach the server and none of them are meant to. What they reach is the
    /// database and the transcript: a question left pending keeps its buttons on a row nobody can
    /// answer any more, and the next launch's sweep files it as "Bloom was not running when this
    /// was asked", which is untrue and is not what the person saw. `stopped` is what happened,
    /// and it is the same word the Claude Code side writes for the same moment.
    ///
    /// The chat can be sent to again afterwards: the thread id is stored, so the next turn
    /// reconnects and resumes rather than starting a new conversation.
    public func shutdown() async {
        let intent = handle.intent
        // Settle the old connection's questions before making a replacement possible.
        await filePendingAsks()
        let previous = detachConnection()
        previous?.terminateNow()
        // Detach before publishing cancellation: that row lets a caller send again, and it must
        // not find the dying client. A new turn begun during bookkeeping owns its own state.
        if handle.intent == intent, session.apply(.cancelled).moves { await save(session) }
        await previous?.stop()
    }

    /// Kill the server and forget everything that belonged to it, leaving the chat resumable.
    ///
    /// Split out of `shutdown` because `applyContextWindowChange` needs exactly this and none of
    /// what surrounds it: nothing is being stopped there, so there are no questions to file and
    /// no cancellation to record, and writing either would say a turn had been interrupted when
    /// none was running.
    private func dropConnection() async {
        let previous = detachConnection()
        await previous?.stop()
    }

    /// Detach without suspension so cleanup cannot clear a replacement connection.
    private func detachConnection() -> CodexClient? {
        let previous = client
        client = nil
        connectionID = UUID()
        // The thread belonged to the process that has just been killed. Held on to, the next
        // message would open a turn on a thread the new server has never heard of; cleared, the
        // stored id on the session row makes that message a `thread/resume`, which is the whole
        // reason the id is on the row.
        threadID = nil
        subagents = CodexSubagents()
        childTurns.replace([:])
        sink.noteProcessEnded()
        items.removeAll()
        pumpTask?.cancel()
        pumpTask = nil
        handle.end()
        return previous
    }

    /// Pick up a context window chosen since this server started, by starting another one.
    ///
    /// **The one composer setting that cannot travel with the turn.** Model, effort, approval
    /// policy and sandbox are all arguments of `turn/start`, which is what makes changing a chip
    /// mid chat take effect on the next message with nothing restarted. `model_context_window`
    /// and `model_auto_compact_token_limit` are `-c` overrides read when `codex app-server`
    /// starts, so a chat left on the old connection would go on running at the old window while
    /// the picker said otherwise, which is the failure this whole setting exists to fix.
    ///
    /// The chat survives it: the thread id is on the session row, so the next `openThread` is a
    /// `thread/resume` rather than a new conversation. What does not survive is anything that
    /// lived only inside the process, which is the grants somebody gave with "allow for this
    /// session"; the same cost `terminateNow` pays, and the reason this reconnects only when the
    /// value has actually changed rather than on every turn.
    private func applyContextWindowChange() async {
        let stored = try? await store.setting(
            ComposerControls.contextWindowKey(sessionID: session.id)
        )
        let wanted = CodexContextWindow.normalised(stored)
        guard wanted != contextWindow else { return }
        contextWindow = wanted
        guard client != nil else { return }
        connection.current?.terminateNow()
        await dropConnection()
    }

    // MARK: - Connecting

    private func connected() async throws -> CodexClient {
        if let client {
            guard session.state != .running && session.state != .waiting else { return client }
            let connected = await client.isConnected
            guard self.client === client else { return try await self.connected() }
            guard !connected, session.state != .running && session.state != .waiting else { return client }
            // The event pump may still be draining the previous process's output. Reconnect
            // before starting a new turn, never by retrying a turn whose request was sent.
            await dropConnection()
            if let client = self.client { return client }
        }

        let stored = try? await store.setting(AgentCatalog.executablePathSettingKey(.codex))
        let execution = try await WorkspaceExecution.resolve(store: store, session: session)
        let client = makeClient(CodexClient.Configuration(
            executable: AgentCatalog.executable(for: .codex, override: stored),
            commandPrefix: execution.commandPrefix,
            cwd: workspacePath,
            clientName: "Bloom",
            clientVersion: Self.clientVersion,
            environment: Shell.environment(extra: execution.environment),
            bridge: execution.commandPrefix.isEmpty ? bridge : nil,
            contextWindow: contextWindow
        ))
        self.client = client
        let connectionID = UUID()
        self.connectionID = connectionID
        connection.attach(client)
        // Attached before the handshake, so nothing the server says between connecting and the
        // first turn can arrive with nowhere to go.
        let events = client.events
        pumpTask = Task { [weak self] in
            for await event in events {
                await self?.handle(event, connectionID: connectionID)
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
        let instructions = session.workspaceID == nil ? AskConversation.instructions : nil
        let handle: CodexThreadHandle
        if let stored = session.agentSessionID, !stored.isEmpty {
            handle = try await client.resumeThread(
                stored, cwd: workspacePath, sandbox: sandbox, developerInstructions: instructions
            )
        } else {
            handle = try await client.startThread(
                cwd: workspacePath,
                model: wireModel,
                approvalPolicy: Self.approvalPolicy(for: session.permissionMode),
                sandbox: sandbox,
                approvalsReviewer: Self.approvalsReviewer(for: session.permissionMode),
                developerInstructions: instructions
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

    /// How Bloom's five modes reach a protocol that has no modes.
    ///
    /// Codex crosses an approval policy with a sandbox and a reviewer, and the grid does not line
    /// up with the picker: `plan` has no equivalent at all and must not be offered for a Codex
    /// chat. The other four are exactly Codex's own four presets, which is not a coincidence but
    /// the point, and their labels come out of `PermissionVocabulary`:
    ///
    /// | Bloom | Codex preset | policy | sandbox | reviewer |
    /// | --- | --- | --- | --- | --- |
    /// | `auto` | `read-only` | `on-request` | `read-only` | `user` |
    /// | `acceptEdits` | `workspace` | `on-request` | `workspace-write` | `user` |
    /// | `autoReview` | `auto` | `on-request` | `workspace-write` | `auto_review` |
    /// | `bypassPermissions` | `full-access` | `never` | `danger-full-access` | `user` |
    public static func approvalPolicy(for mode: PermissionMode) -> CodexApprovalPolicy {
        switch mode {
        case .bypassPermissions: .never
        // `untrusted` asks about nearly everything, including reads, which is a mode nobody leaves
        // on. `on-request` is the one that asks about what the sandbox refused.
        case .auto, .acceptEdits, .autoReview, .plan: .onRequest
        }
    }

    public static func sandboxMode(for mode: PermissionMode) -> CodexSandboxMode {
        switch mode {
        case .bypassPermissions: .dangerFullAccess
        // Approve for me differs from Ask for approval in who answers, not in what is asked, so
        // the two share a sandbox. `codex --approve-for-me` says the same thing in its own help:
        // "Route approval requests through automatic review using the workspace-write sandbox."
        case .acceptEdits, .autoReview: .workspaceWrite
        // Read only and Plan both mean "do not write without telling me". Read-only is the sandbox
        // that means it, and a write then arrives as a question rather than as a fact.
        case .auto, .plan: .readOnly
        }
    }

    /// Who answers, which is the whole of what Approve for me adds.
    ///
    /// **Sent on every turn, including the modes that want the default.** The field is sticky on
    /// this protocol, "this turn and subsequent turns", so a chat that ran one turn as Approve for
    /// me and was then moved back would keep the reviewer it had while the chip in the composer
    /// said otherwise. Naming it every time is what keeps the chip and the server in step.
    public static func approvalsReviewer(for mode: PermissionMode) -> CodexApprovalsReviewer {
        switch mode {
        case .autoReview: .autoReview
        case .auto, .acceptEdits, .bypassPermissions, .plan: .user
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

    private var subagents = CodexSubagents()
    private nonisolated let childTurns = CodexChildTurns()

    public nonisolated var supportsConversationRewind: Bool { true }

    public func rewind(beforeTurnID: String) async throws {
        guard !isRewinding, sendsInFlight == 0, handle.turnID == nil,
              pending.isEmpty, !sink.hasBackgroundWork else { throw ConversationRewindError.busy }
        isRewinding = true
        defer { isRewinding = false }
        let connection = try await connected()
        let thread = try await openThread(on: connection)
        try await connection.rewindThread(threadID: thread, beforeTurnID: beforeTurnID)
        items.removeAll()
    }

    public func containsTurn(_ turnID: String) async throws -> Bool {
        guard sendsInFlight == 0, handle.turnID == nil, pending.isEmpty else { throw ConversationRewindError.busy }
        let connection = try await connected()
        let thread = try await openThread(on: connection)
        return try await connection.threadContainsTurn(threadID: thread, turnID: turnID)
    }

    public func subagentTranscript(for id: SubagentID) async -> SubagentTranscript? {
        guard let child = subagents.threadID(for: id), let client,
              let result = try? await client.send("thread/read", params: .object([
                  "threadId": .string(child), "includeTurns": .bool(true),
              ]), timeout: .seconds(10)),
              result["thread"]?["id"]?.stringValue == child else { return nil }
        return CodexSubagentTranscript.read(result["thread"] ?? .null, sessionID: session.id)
    }

    private func handle(_ event: CodexEvent, connectionID: UUID) async {
        guard connectionID == self.connectionID else { return }
        if case .itemCompleted(let item) = event, case .plan(let plan) = item.item,
           item.threadID == threadID {
            _ = try? await store.recordPlan(sessionID: session.id, sourceID: plan.id, markdown: plan.text)
            // Saving a plan can suspend while a replacement connection takes over.
            guard connectionID == self.connectionID else { return }
        }
        if let threadID {
            let previousChildTurns = subagents.liveTurns
            for signal in subagents.receive(event, parentThreadID: threadID) {
                sink.yield(.subagent(signal))
            }
            childTurns.replace(subagents.liveTurns)
            if handle.wasCancelled, let client {
                let arrived = subagents.liveTurns.filter { previousChildTurns[$0.key] != $0.value }
                if !arrived.isEmpty {
                    Task {
                        await CodexFamilyStop.interrupt(arrived) { child, turn, timeout in
                            try? await client.interruptTurn(threadID: child, turnID: turn, timeout: timeout)
                        }
                    }
                }
            }
            if let source = event.threadID, source != threadID {
                // Child approvals still need an answer, but their prose, usage and completion
                // belong to the child pane, never to the parent's transcript or turn handle.
                if subagents.contains(threadID: source) {
                    remember(event)
                    if case .approval(let request) = event { await ask(request) }
                }
                return
            }
            switch event {
            case .itemStarted(let item), .itemCompleted(let item):
                if case .subAgentActivity(let activity) = item.item,
                   activity.agentThreadID == threadID { return }
            default:
                break
            }
        }
        let endingTurn: String? = switch event {
        case .turnCompleted(let turn): turn.id
        case .turnError(let failure) where !failure.willRetry: failure.turnID
        default: nil
        }
        // Filter before forgetting item metadata too: an old completion must not erase the
        // command or file details used to explain a question from the newer turn.
        if let endingTurn, !handle.acceptsTerminal(turnID: endingTurn) { return }
        remember(event)

        if case .unknown(let method, let raw) = event, method == "serverRequest/resolved",
           let json = try? JSONDecoder().decode(JSONValue.self, from: raw),
           let id = CodexRequestID(json["params"]?["requestId"]),
           let threadID = json["params"]?["threadId"]?.stringValue {
            let requestID = CodexPermission.requestID(id, threadID: threadID, connectionID: connectionID)
            if let ask = pending.take(requestID) {
                await close(ask, as: PermissionAskOutcome.resolved, note: "")
                if pending.isEmpty, session.apply(.unblocked).moves { await save(session) }
            }
            return
        }

        // A connection that closed because Bloom closed it is not news, and it must not be drawn
        // as an outage. `.closed` translates to an `.error`, which the window puts up as "The
        // agent stopped in <workspace>", so a chat whose workspace was archived, removed or simply
        // closed produced a modal saying the Codex process had ended: true, and the owner is the
        // one who ended it. Only a server that went away on its own is worth a word.
        if case .closed = event {
            client = nil
            threadID = nil
            if handle.wasCancelled || trouble.hasStopped || (session.state != .running && session.state != .waiting) { return }
        }

        if case .approval(let request) = event {
            await ask(request)
            return
        }

        for translated in translation.translate(event) {
            await emit(translated, endingTurn: endingTurn)
        }
    }

    /// Keep the items a question might be about, and forget them when the turn that made them ends.
    private func remember(_ event: CodexEvent) {
        switch event {
        case .itemStarted(let started), .itemCompleted(let started):
            items[started.threadID, default: [:]][started.item.id] = started.item
        case .turnCompleted(let turn):
            items.removeValue(forKey: turn.threadID)
        default:
            break
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

        // Persistence suspends too. A terminal row already written stays in the history, but a
        // late event must not move the current lifecycle or announce completion to the window.
        if let endingTurn, !handle.acceptsTerminal(turnID: endingTurn, intent: intent) { return }

        switch event {
        case .result(let result):
            handle.end()
            session.apply(.turnFinished(isError: result.isError))
            session = session.with {
                $0.inputTokens += result.usage.inputTokens
                $0.outputTokens += result.usage.outputTokens
                // No price reaches this protocol, so `costUSD` is deliberately never touched: a
                // number that means "we do not know" must not be added to one that means dollars.
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

    private func ask(_ request: CodexApprovalRequest) async {
        let ask = CodexPermission.ask(for: request, item: items[request.threadID]?[request.itemID], connectionID: connectionID)
        pending.add(ask)
        approvals[ask.requestID] = request

        do {
            try await store.appendPermissionAsk(sessionID: session.id, ask: ask)
        } catch {
            await report("could not store a permission question", error)
        }
        await persist(kind: .permissionAsk, payload: ask.raw, refID: ask.toolUseID)

        // Yielded before the grant lookup, exactly as the Claude Code side does it: a question a
        // stored rule answers is decided in the same breath it arrives, and a decision reaching a
        // view before the question it decides leaves the view with no row to settle.
        sink.yield(.permissionAsk(ask))

        let matched = await grants.matching(ask)
        if let matched, let claimed = pending.take(ask.requestID) {
            await write(answerTo: claimed, decision: .acceptForSession)
            await close(claimed, as: PermissionAskOutcome.auto, note: PermissionGrantIndex.note(for: matched))
            await grants.recordUse(of: matched)
            return
        }

        guard matched == nil, pending.contains(ask.requestID) else { return }

        guard request.kind != .toolUserInput || request.params["isBlocking"]?.boolValue != false else { return }
        session.apply(.blocked)
        await save(session)
    }

    /// Put the words into the turn that is already running, and say whether they landed.
    ///
    /// **A miss is not a failure, it is a turn that ended under the read.** `expectedTurnId` is a
    /// precondition on this wire, so the server refuses a steer for a turn that is no longer the
    /// active one, and the message wants an ordinary `turn/start` after all. `send` then carries
    /// on down the path it always took.
    ///
    /// **This is a race guard and not a state guard, and the difference cost a regression.** It
    /// only fires for a turn that finished between `handle.steerableTurnID` being read and this
    /// request landing, because `end()` runs on the actor and this call suspends. A turn somebody
    /// STOPPED is a state rather than a race: the id is still there, the server may well take the
    /// steer, and nothing here would have said no. That is what `steerableTurnID` asks, before
    /// this is reached.
    private func steer(
        _ text: String, threadID: String, turnID: String, on client: CodexClient
    ) async throws -> Bool {
        do {
            _ = try await client.steerTurn(threadID: threadID, turnID: turnID, input: [.text(text)])
            return true
        } catch {
            guard CodexSendRecovery.permitsNewTurn(after: error) else { throw error }
            Self.log.info("a message missed the turn it was steered into, so it starts one")
            return false
        }
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
    private func deliverReason(of decision: PermissionDecision, request: CodexApprovalRequest?) async {
        guard case .deny(let message, let endsTurn) = decision, !endsTurn else { return }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let client, let request, !request.turnID.isEmpty else { return }
        _ = try? await client.steerTurn(
            threadID: request.threadID, turnID: request.turnID, input: [.text(text)]
        )
    }

    private func write(
        answerTo ask: PermissionAsk, decision: CodexApprovalDecision, answerInput: JSONValue? = nil
    ) async {
        if let request = approvals.removeValue(forKey: ask.requestID) {
            if request.kind == .toolUserInput, let answerInput {
                await client?.answer(request.id, with: CodexQuestionnaire.result(input: answerInput, request: request))
            } else {
                await client?.answer(request, decision: decision)
            }
        }

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

    /// Writes the columns this runner owns, and nothing else. The same rule as `AgentRunner`: a
    /// whole-value write would put back a title, a model or a read mark from whenever this runner
    /// last read the row. `state` is carried rather than decided here too: nothing in this file
    /// assigns it, so what lands on the row is whatever `SessionLifecycle` allowed.
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

    /// Say so when the store refuses a write, on the stream as well as on the runner, unless there
    /// is nobody left to say it to.
    ///
    /// The sink rather than `emit`, twice over: persisting a row is exactly what just failed, and
    /// `emit`'s `.error` arm ends the turn, which a database hiccup has no business doing. The
    /// Claude Code side has emitted this event since its `try?` swallowed a whole transcript;
    /// this backend used to keep the count and tell nobody who was looking at the window.
    ///
    /// The silence, and why only this one refusal gets it, is written out in full at
    /// `AgentRunner.report`. Both backends have to make the same call, because both of them can be
    /// mid turn when a workspace is archived or removed and the session row goes.
    private func report(_ what: String, _ error: Error) async {
        // The log keeps what the person is not shown: which write it was, and the statement.
        Self.log.error("\(what, privacy: .public): \(error.readableMessage, privacy: .public)")

        let standing = await TranscriptStanding.of(sessionID: session.id, in: store)
        switch trouble.record(WorkspaceTrouble.recording(
            transcript: standing, complaint: TranscriptStanding.complaint(about: error)
        )) {
        case .tell(let sentence):
            sink.yield(.error(.storage(message: sentence)))
        case .stop:
            // Kills the server rather than interrupting the turn, which is where the two backends
            // part company: `cancelNow` here would leave `codex app-server` running in a worktree
            // that is being deleted. See `SessionRunner.terminateNow`.
            Self.log.info("the transcript for \(self.session.id.rawValue, privacy: .public) has been removed, so this run is being stopped without a word")
            terminateNow()
        case .alreadyStopped:
            break
        }
    }

    /// Whether this run has been stopped because its transcript was deleted underneath it. For
    /// the suite, and for the same reason as `AgentRunner.hasBeenCancelled`.
    var transcriptWasRemoved: Bool { trouble.hasStopped }

    private static let log = CoreLogger(
        subsystem: Bundle.main.bundleIdentifier ?? "be.spatie.bloom",
        category: "codex-runner"
    )
}

/// The live connection, where synchronous code can reach it. See `CodexRunner.terminateNow`.
private final class LiveConnection: Sendable {
    private let client = Mutex<CodexClient?>(nil)

    var current: CodexClient? { client.withLock { $0 } }

    func attach(_ client: CodexClient) {
        self.client.withLock { $0 = client }
    }
}
