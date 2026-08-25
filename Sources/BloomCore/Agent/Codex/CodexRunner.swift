import Foundation
import Synchronization
import os

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
    private var cancelled = false
    private var cachedRepoID: RepoID?

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

    /// The live connection, held outside the actor so quit, close and archive can signal the
    /// server without waiting for a turn on one. Attached on every connect and never cleared, for
    /// the reason `LiveProcess` in `CodexClient` gives: a box emptied by the bookkeeping running
    /// behind the signal would answer "gone" for a process that was still dying.
    private let connection = LiveConnection()

    private let pending = PendingAsks()
    private let handle = TurnHandle()
    private let sink = EventFanout<AgentEvent>()

    /// Whether this run has already been stopped because its transcript was deleted underneath
    /// it. See `stopBecauseTheTranscriptWentAway`.
    private var transcriptWentAway = false
    private var persistenceFailures = 0
    private var lastFailure: String?

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

    /// Whether the server process is still there, which on this backend is **not** whether a turn
    /// is running.
    ///
    /// The two are one fact for Claude Code, whose process is killed by Stop and started again by
    /// the next turn, and two facts here: `codex app-server` is long lived by design and outlives
    /// every turn on it. A quit path polling "is a turn open" watched the interrupt land, saw the
    /// turn close and concluded the process was gone. It was not. It had never been signalled.
    public var isProcessAlive: Bool { connection.current?.isProcessAlive ?? false }

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

        session.apply(.turnStarted)
        await save(session)
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
        handle.markCancelled()
        Task { await self.stopTurn() }
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
    private func stopTurn() async {
        await filePendingAsks()
        await interrupt()
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

    private func interrupt() async {
        cancelled = true
        // Written here rather than left for the result to infer, which is what the `cancelled`
        // flag used to do at both of the sites below. `SessionLifecycle` refuses a stop on a
        // session with no turn open and ignores a result on one that has already been stopped, so
        // the two facts are stated once each instead of being recombined by a ternary twice.
        if session.apply(.cancelled).moves { await save(session) }
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
        if let repoID = await repoID() {
            for grant in PermissionGrant.all(granting: decision, from: ask, repoID: repoID) {
                _ = try? await store.upsert(grant)
            }
        }
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
        await filePendingAsks()
        // Stated here as well as in `interrupt`, because a chat can be closed while it is idle
        // and can be closed while it is mid turn. `SessionLifecycle` refuses a stop on a session
        // with no turn open, so the one that did not happen writes nothing.
        if session.apply(.cancelled).moves { await save(session) }
        await client?.stop()
        client = nil
        // The thread belonged to the process that has just been killed. Held on to, the next
        // message would open a turn on a thread the new server has never heard of; cleared, the
        // stored id on the session row makes that message a `thread/resume`, which is the whole
        // reason the id is on the row.
        threadID = nil
        items.removeAll()
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
            clientVersion: Self.clientVersion,
            bridge: bridge
        ))
        self.client = client
        connection.attach(client)
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

        // A connection that closed because Bloom closed it is not news, and it must not be drawn
        // as an outage. `.closed` translates to an `.error`, which the window puts up as "The
        // agent stopped in <workspace>", so a chat whose workspace was archived, removed or simply
        // closed produced a modal saying the Codex process had ended: true, and the owner is the
        // one who ended it. Only a server that went away on its own is worth a word.
        if case .closed = event, handle.wasCancelled || transcriptWentAway { return }

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
            await report("could not store a permission question", error)
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

        session.apply(.blocked)
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

    private func repoID() async -> RepoID? {
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
            await report("could not store a \(kind.rawValue) row", error)
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
        guard let trouble = WorkspaceTrouble.recording(
            transcript: standing, complaint: TranscriptStanding.complaint(about: error)
        ) else {
            stopBecauseTheTranscriptWentAway()
            return
        }

        persistenceFailures += 1
        lastFailure = trouble.sentence
        sink.yield(.error(.storage(message: trouble.sentence)))
    }

    /// The workspace this session belonged to has been removed. Stop the process and say nothing.
    /// Guarded, and for the same reason as its twin: everything already in flight when the rows
    /// went will be refused on its way through, and one stop answers all of it.
    private func stopBecauseTheTranscriptWentAway() {
        guard !transcriptWentAway else { return }
        transcriptWentAway = true
        Self.log.info("the transcript for \(self.session.id.rawValue, privacy: .public) has been removed, so this run is being stopped without a word")
        terminateNow()
    }

    /// Whether this run has been stopped because its transcript was deleted underneath it. For
    /// the suite, and for the same reason as `AgentRunner.hasBeenCancelled`.
    var transcriptWasRemoved: Bool { transcriptWentAway }

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "be.spatie.bloom",
        category: "codex-runner"
    )
}

// MARK: - Turn handle

/// What a turn is, from outside the actor.
///
/// Stop is pressed from synchronous main-actor code, and the actor at that moment is busy running
/// the thing being stopped. The intent has to be recorded where it can be read without waiting.
///
/// `Mutex<State>` rather than `NSLock` plus `@unchecked Sendable`, for the reason given on
/// `EventFanout` in `SessionRunner`: `@unchecked` is a promise the compiler cannot check, and
/// the two fields below have to move together.
private final class TurnHandle: Sendable {
    private struct State {
        var current: String?
        var cancelled = false
    }

    private let state = Mutex(State())

    var turnID: String? { state.withLock(\.current) }

    var wasCancelled: Bool { state.withLock(\.cancelled) }

    func begin(turnID: String) {
        state.withLock { state in
            state.current = turnID
            state.cancelled = false
        }
    }

    func markCancelled() {
        state.withLock { $0.cancelled = true }
    }

    func end() {
        state.withLock { $0.current = nil }
    }
}

/// The live connection, where synchronous code can reach it. See `CodexRunner.terminateNow`.
private final class LiveConnection: Sendable {
    private let client = Mutex<CodexClient?>(nil)

    var current: CodexClient? { client.withLock { $0 } }

    func attach(_ client: CodexClient) {
        self.client.withLock { $0 = client }
    }
}
