import SwiftUI
import Observation
import BloomCore

/// One renderable row in a transcript.
///
/// It deliberately carries the raw JSON rather than a decoded structure. The store keeps every
/// event verbatim, so a renderer added later can show detail that was not decoded when the row
/// was written, and a row costs nothing to hold until it scrolls into view.
struct TranscriptRow: Identifiable, Hashable {
    var id: Int64
    var seq: Int
    var kind: MessageKind
    var payload: Data
    var createdAt: Date
    var durationMS: Int?
    var refID: String?

    /// Set once the matching tool_result arrives, so a tool call and its outcome render as one row.
    var resultPayload: Data?
    var isError = false
    /// Set when the result says the call never ran, and why. A refusal carries `is_error` as well,
    /// so the two are held together and every reader that draws a failure checks this first.
    var refusal: ToolRefusal?
    /// The one line the CLI gave for a refusal, so a collapsed row can say what happened without
    /// decoding a result payload that is usually the largest in the session.
    var refusalReason = ""
    /// Non-nil when the row came from inside a subagent, so it can be indented under its parent.
    var parentToolUseID: String?

    /// For a `permissionAsk` row: how the question was settled, or nil while it is still open.
    ///
    /// Held on the row rather than looked up per frame, because the answer decides whether the row
    /// draws live buttons, and a row that offers buttons for a question already answered would
    /// write into a pipe nobody is reading.
    var permissionDecision: String?
    /// What the transcript should say about how it was settled, when that is not obvious. Only
    /// ever set for a question a rule answered rather than a person.
    var permissionNote = ""

    init(message: Message) {
        id = message.id
        seq = message.seq
        kind = message.kind
        payload = message.payload
        createdAt = message.createdAt
        durationMS = message.durationMS
        refID = message.refID
    }
}

/// The state behind one session's transcript: the rows, whether the agent is running, and the
/// partial text currently streaming in.
@MainActor
@Observable
final class TranscriptModel {
    var session: Session
    let workspace: Workspace
    private unowned let app: AppModel

    private(set) var rows: [TranscriptRow] = []
    /// Whether this session's agent is mid turn.
    ///
    /// Computed over one stored flag rather than being the stored flag, so that every change to
    /// it goes through `setRunning` and the app can be told. Reading it still registers a
    /// dependency on `storedIsRunning`, which is what a view needs.
    var isRunning: Bool { storedIsRunning }
    private var storedIsRunning = false

    /// Whether this session's agent has stopped and is waiting on a person.
    ///
    /// A stored flag for exactly the reason `isRunning` is one, and not a walk over `rows` looking
    /// for an unanswered question. `rows` is observable, so a derived answer would technically
    /// invalidate, but it would also be recomputed on every streamed token of every turn, and the
    /// readers that need this (the sidebar mark, the Dock badge, the menu bar count) are not in a
    /// position to walk anything: see `AppModel.waitingWorkspaceIDs`.
    var isAwaitingPermission: Bool { storedIsAwaitingPermission }
    private var storedIsAwaitingPermission = false
    private(set) var isLoaded = false

    /// Text and thinking arriving live, before the completed block is persisted.
    private(set) var streamingText = ""
    private(set) var streamingThinking = ""
    private(set) var streamingToolName: String?
    private(set) var thinkingTokens = 0
    private(set) var statusLabel: String?

    var draft = ""

    /// Bumped whenever something outside the list asks it to go back to the newest row. A counter
    /// rather than a flag, so two requests in a row are two requests, and the list has nothing to
    /// clear afterwards. See `jumpToLiveEnd`.
    private(set) var liveEndRequests = 0

    private var runner: (any SessionRunner)?
    private var pumpTask: Task<Void, Never>?
    private var indexByRefID: [String: Int] = [:]
    /// The one read of this session's history, held so that it happens once however many callers
    /// ask for it.
    ///
    /// Two of them do, and both arrive before it has finished: `WorkspaceModel.transcript(for:)`
    /// reads a model eagerly the moment it builds one, and `TranscriptListView`'s own task reads it
    /// again when the pane draws. `isLoaded` cannot keep them apart, since it is only true on the
    /// last line of the read. `SingleFlight` is named after, and documents, the transcript that
    /// would not draw when the two of them ran the read at once.
    private let loader = SingleFlight()
    /// When the current turn was handed to the runner, so a session row written before that can be
    /// recognised as belonging to the previous turn.
    private var turnStartedAt: Date?

    init(session: Session, workspace: Workspace, app: AppModel) {
        self.session = session
        self.workspace = workspace
        self.app = app
    }

    private var store: Store? { app.store }

    // MARK: - Loading

    func load() async {
        guard let store, !isLoaded else {
            SwitchTrace.mark("transcript.reused", workspace: workspace.id)
            SwitchTrace.markOnScreen("transcript.reused", workspace: workspace.id)
            return
        }
        // Whichever of the two callers gets here first does the reading, and the other waits on it.
        // The guard above cannot tell them apart, because neither of them is reusing anything: they
        // are both asking for the same session's history at the same moment.
        await loader.run { [self] in await read(from: store) }
    }

    /// The read itself, reached only through `loader`.
    ///
    /// The rows are built into a list off to one side and put on the model in one assignment at the
    /// end, rather than the model's own list being emptied and then filled. There is an await in
    /// the middle of this and there will probably be another one day, and a half built row list
    /// must never be observable: a `ForEach` handed rows whose identifiers repeat lays them out in
    /// whatever order it pleases, and that is what left an answer undrawn until the scroller was
    /// dragged.
    private func read(from store: Store) async {
        SwitchTrace.mark("transcript.read.start", workspace: workspace.id)
        let messages = (try? await store.messages(sessionID: session.id)) ?? []
        SwitchTrace.mark("transcript.read.done", workspace: workspace.id)
        // Read once for the whole session rather than per row: a transcript can hold thousands of
        // rows and at most a handful of them are questions.
        let decisions = (try? await store.permissionAskDecisions(sessionID: session.id)) ?? [:]

        var built: [TranscriptRow] = []
        var index: [String: Int] = [:]
        for message in messages {
            Self.absorb(message, decisions: decisions, into: &built, indexByRefID: &index)
        }
        rows = built
        indexByRefID = index
        SwitchTrace.mark("transcript.rows.built", workspace: workspace.id)
        SwitchTrace.markOnScreen("transcript.rows.built", workspace: workspace.id)

        draft = (try? await store.draft(sessionID: session.id)) ?? ""
        isLoaded = true
    }

    /// Folds a stored message into the row list, pairing tool results onto their tool call.
    ///
    /// Handed the list and the reference index it is folding into rather than reaching for the
    /// model's own, so that the same rule can build a whole session's rows somewhere nothing can
    /// see them. See `read(from:)` for why that matters.
    private static func absorb(
        _ message: Message,
        decisions: [String: String],
        into rows: inout [TranscriptRow],
        indexByRefID: inout [String: Int]
    ) {
        if message.kind == .toolResult, let refID = message.refID,
           let index = indexByRefID[refID] {
            rows[index].resultPayload = message.payload
            let summary = ToolResultSummary.decode(message.payload)
            rows[index].isError = summary.isError
            rows[index].refusal = summary.refusal
            rows[index].refusalReason = summary.reason
            if let duration = message.durationMS { rows[index].durationMS = duration }
            return
        }

        var row = TranscriptRow(message: message)
        row.parentToolUseID = ParentProbe.parentToolUseID(message.payload)
        if message.kind == .permissionAsk,
           let ask = PermissionAsk.decode(payload: message.payload) {
            row.permissionDecision = decisions[ask.requestID]
        }
        rows.append(row)
        if message.kind == .toolUse, let refID = message.refID {
            indexByRefID[refID] = rows.count - 1
        }
    }

    /// The same fold, straight onto the model, for the rows that arrive while the session is open.
    private func absorb(_ message: Message, decisions: [String: String] = [:]) {
        Self.absorb(message, decisions: decisions, into: &rows, indexByRefID: &indexByRefID)
    }

    // MARK: - Unread

    var firstUnreadSeq: Int? {
        rows.first { $0.seq > session.lastReadSeq }?.seq
    }

    func markAllRead() async {
        guard let store, let last = rows.last?.seq, last != session.lastReadSeq else { return }
        session.lastReadSeq = last
        try? await store.updateLastReadSeq(sessionID: session.id, seq: last)
    }

    /// Pulls the session row back from the store. Anything the runner owns (the agent session
    /// id, the state, the counters) only ever travels in this direction.
    func refreshSession() async {
        guard let store, let fresh = try? await store.session(id: session.id) else { return }
        session = fresh
        // The runner owns the state column, and it writes a terminal state from paths that do not
        // always reach the UI as an event. Trusting the row here is what keeps the composer from
        // spinning against an agent that is already gone. A row last written before the current
        // turn started still describes the previous one, so it says nothing about this turn.
        let isStale = turnStartedAt.map { fresh.updatedAt < $0 } ?? false
        if !isStale, fresh.state == .failed || fresh.state == .cancelled {
            setRunning(false)
            statusLabel = nil
        }
    }

    /// The pickers in the composer write through here so they touch only their own columns.
    func updatePreferences(
        title: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        permissionMode: PermissionMode? = nil
    ) async {
        guard let store else { return }
        try? await store.updateSessionPreferences(
            id: session.id, title: title, model: model, effort: effort, permissionMode: permissionMode
        )
        await refreshSession()
    }

    /// Asks the list to go back to the newest row.
    ///
    /// The live end rather than a row, and that is the whole of what changed here. This used to
    /// name `firstUnreadSeq` and scroll to it, which asks the list for a position inside its lazy
    /// stack, and a stack that is drawing the end of a long session does not necessarily hold that
    /// row yet. An edge needs no identity and is always there.
    func jumpToLiveEnd() {
        liveEndRequests += 1
    }

    // MARK: - Sending

    func send(_ text: String) async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let store else { return }

        draft = ""
        try? await store.saveDraft(sessionID: session.id, body: "")

        let runner = ensureRunner()
        turnStartedAt = Date()
        setRunning(true)
        statusLabel = "Starting"

        do {
            try await runner.send(body)
        } catch {
            setRunning(false)
            statusLabel = nil
            // The composer was emptied on the assumption the turn would start. It did not, so
            // the words go back where they were typed. An unsent prompt is often minutes of
            // thought and this app holds the only copy of it; an alert the user cannot paste
            // out of is not somewhere to leave it.
            //
            // Prepended rather than assigned when something is already there, because the only
            // way that happens is somebody typing while the start failed, and their new sentence
            // is not this method's to throw away either.
            draft = draft.isEmpty ? body : body + "\n\n" + draft
            try? await store.saveDraft(sessionID: session.id, body: draft)
            Log.composer.error(
                "the agent would not start, so the prompt was put back in the composer: \(error.readableMessage, privacy: .public)"
            )
            app.alert = BloomAlert(title: "Could not start the agent", message: error.readableMessage)
        }
    }

    func saveDraft() async {
        guard let store else { return }
        try? await store.saveDraft(sessionID: session.id, body: draft)
    }

    /// The one place `isRunning` moves.
    ///
    /// Seven call sites set it, and every one of them also has to reach `AppModel`, because the
    /// sidebar's status strip, Home's summary line, the menu bar item, the Dock badge and the
    /// sleep assertion are all answers to "is anything running" and none of them can see this
    /// object. `AppModel.runningWorkspaceIDs` explains why they cannot simply read it: the model
    /// dictionary those readers would have to walk is outside observation on purpose.
    ///
    /// Idempotent, so a path that stops an already stopped turn writes nothing and invalidates
    /// nobody.
    private func setRunning(_ value: Bool) {
        // A turn that has ended cannot still be waiting on a question, and there are six places
        // that end one: a stale terminal state read back from the row, a send that threw, Stop,
        // quit, the agent dying, and the result line. Clearing it here rather than at all six is
        // the same argument that made this method exist, and it happens before the guard because
        // the two flags can disagree: a turn stopped while blocked is already not running.
        if !value { setAwaitingPermission(false) }

        guard storedIsRunning != value else { return }
        storedIsRunning = value
        app.noteRunningChanged(workspaceID: workspace.id)
    }

    /// The one place `isAwaitingPermission` moves, for the same reasons `setRunning` is the one
    /// place `isRunning` does.
    ///
    /// Idempotent, so answering the second of two questions writes nothing.
    private func setAwaitingPermission(_ value: Bool) {
        guard storedIsAwaitingPermission != value else { return }
        storedIsAwaitingPermission = value
        app.noteWaitingChanged(workspaceID: workspace.id)
    }

    /// Recompute from the questions actually outstanding. Called wherever one is added or settled,
    /// so a turn that asked three things goes back to running only when the last is answered.
    private func refreshAwaitingPermission() {
        setAwaitingPermission(!pendingPermissionAsks.isEmpty)
    }

    /// The UI stops looking busy right away, but the pump is deliberately left running: a cancelled
    /// turn still emits its own result, and that event is what writes the final state back into the
    /// session row. Tearing the pump down here used to strand the session until the next launch.
    func stop() {
        runner?.cancelNow()
        setRunning(false)
        statusLabel = nil
        clearStreaming()
    }

    /// The session itself is going away, so the pump goes with it. The event stream never ends on
    /// its own, and a pump left iterating one holds its runner alive for the rest of the launch.
    func teardown() {
        stop()
        pumpTask?.cancel()
        pumpTask = nil
    }

    /// Quit path. Signals the agent and waits, briefly, for it to actually be gone, because macOS
    /// hands our children to launchd rather than killing them.
    func shutdown() async {
        guard let runner else { return }
        runner.cancelNow()
        setRunning(false)
        statusLabel = nil
        clearStreaming()

        let deadline = ContinuousClock.now.advanced(by: .seconds(3.5))
        while ContinuousClock.now < deadline {
            let alive = await runner.isRunning
            if !alive { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Starts the runner and the event pump on first use. The pump is rebuilt whenever it is
    /// missing, so no path can leave a live runner with nothing reading its events.
    ///
    /// Which runner is the chat's own answer, read off `session.agentKind`, and it is read once:
    /// a chat that has started is on the backend it started on for as long as it lives. Changing
    /// the picker on a chat that has already spoken forks a new chat rather than turning this one
    /// into something else, because its rows, its thread and its context all belong to the backend
    /// that made them. See `ComposerBackendChange` and docs/CODEX.md.
    private func ensureRunner() -> any SessionRunner {
        let runner = self.runner ?? Self.makeRunner(
            session: session,
            workspacePath: workspace.path,
            store: app.store!,
            bridge: app.bridge?.register(session: session, workspace: workspace)
        )
        self.runner = runner
        if pumpTask == nil { startPump(on: runner) }
        return runner
    }

    /// The one place a backend becomes a process. Static and taking only values, so which runner a
    /// session gets can be asserted on without a workspace, a store or a view.
    ///
    /// It is also the one place the workspace bridge is registered, and that is not a coincidence:
    /// the bridge is per process, so it belongs wherever the process is decided. A runner built
    /// anywhere else would be a second CLI on the same session row, which is the invariant
    /// `BridgeServer` refuses to touch and the reason nothing on the bridge's side of the socket
    /// may build one.
    static func makeRunner(
        session: Session,
        workspacePath: String,
        store: Store,
        bridge: BridgeHandle? = nil
    ) -> any SessionRunner {
        switch session.agentKind {
        case .codex:
            return CodexRunner(
                workspacePath: workspacePath,
                session: session,
                store: store,
                bridge: bridge?.attachment
            )
        // Cursor and OpenCode have no runner, and `AgentKind.canRunWorkspaces` is what stops a
        // chat ever being on one. A chat that somehow is falls back to Claude Code rather than
        // refusing to start, because a transcript that cannot be typed into is a worse answer
        // than one running the backend every existing chat already runs.
        case .claudeCode, .cursor, .openCode:
            return AgentRunner(
                workspacePath: workspacePath,
                session: session,
                store: store,
                mcpConfigPath: bridge?.mcpConfigPath
            )
        }
    }

    private func startPump(on runner: any SessionRunner) {
        pumpTask = Task { [weak self] in
            for await event in runner.events {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    // MARK: - Event handling

    private func handle(_ event: AgentEvent) async {
        switch event {
        case .initialized:
            // The runner persists the agent session id itself. Read it back rather than writing
            // our own copy, which would be a second writer racing the runner on the same row.
            await refreshSession()
            statusLabel = "Working"

        case .status(let label):
            statusLabel = label.capitalizedFirst

        case .thinkingTokens(let total):
            thinkingTokens = total

        case .streamDelta(let delta):
            switch delta {
            case .text(let chunk): streamingText += chunk
            case .thinking(let chunk): streamingThinking += chunk
            case .toolName(let name): streamingToolName = name
            case .toolInput: break
            case .blockFinished: break
            }

        case .assistantText, .thinking, .toolUse, .toolResult:
            clearStreaming()
            await appendLatestMessages()

        case .error(let failure):
            // The agent died without ever producing a result: a model it does not know, expired
            // credentials, a crash. Nothing else will arrive, so the turn ends here or the composer
            // stays locked for the rest of the launch.
            clearStreaming()
            await appendLatestMessages()
            setRunning(false)
            statusLabel = nil
            await refreshSession()
            app.alert = BloomAlert(
                title: "The agent stopped in \(workspace.name)",
                message: failure.message.isEmpty ? "It exited without finishing the turn." : failure.message
            )
            NotificationService.shared.agentFailed(workspace: workspace, message: failure.message)

        case .result(let result):
            clearStreaming()
            await appendLatestMessages()
            setRunning(false)
            statusLabel = nil
            // Token counts, cost and state are all written by the runner as part of handling the
            // same result. Reading them back keeps one writer and avoids double counting.
            await refreshSession()
            await notifyFinished(result: result)

        case .permissionAsk:
            // The row goes in where the call would have been, and the composer stops looking like
            // an agent that is working: it is alive, and it is not going anywhere.
            clearStreaming()
            await appendLatestMessages()
            statusLabel = "Waiting on you"
            refreshAwaitingPermission()
            await refreshSession()
            NotificationService.shared.agentNeedsPermission(workspace: workspace)

        case .permissionDecided(let resolution):
            settle(resolution)
            refreshAwaitingPermission()
            if !isAwaitingPermission {
                statusLabel = isRunning ? "Working" : nil
            }
            await refreshSession()

        case .hook, .rateLimit, .unknown:
            break
        }
    }

    // MARK: - Permission asks

    /// What the project is called, for a permission row that has to say where a rule would apply.
    /// "Always allow ... in Bloom" is a promise about a place, and the place has to be named.
    var projectName: String {
        app.repo(for: workspace)?.name ?? workspace.name
    }

    /// The questions this session is holding a turn open for, in the order they arrived.
    var pendingPermissionAsks: [PermissionAsk] {
        rows.compactMap { row in
            guard row.kind == .permissionAsk, row.permissionDecision == nil else { return nil }
            return PermissionAsk.decode(payload: row.payload)
        }
    }

    /// Answer one question. The turn resumes on the other side of this.
    ///
    /// The row is settled here rather than waiting for the event to come back round, so the
    /// buttons stop being pressable the moment one of them is, and a slow store cannot leave two
    /// answers on their way to the same question.
    func answer(requestID: String, decision: PermissionDecision) async {
        settle(PermissionResolution(requestID: requestID, decision: decision.storedName))
        refreshAwaitingPermission()
        await runner?.answer(requestID: requestID, decision: decision)
    }

    /// Mark a question answered on the row that asked it.
    private func settle(_ resolution: PermissionResolution) {
        guard let index = rows.firstIndex(where: {
            $0.kind == .permissionAsk
                && PermissionAsk.decode(payload: $0.payload)?.requestID == resolution.requestID
        }) else { return }

        rows[index].permissionDecision = resolution.decision
        if !resolution.note.isEmpty { rows[index].permissionNote = resolution.note }
    }

    /// Pulls anything the runner has persisted since the last row we hold. The runner is the
    /// single writer, so reading back from the store keeps one ordering and one source of truth.
    private func appendLatestMessages() async {
        guard let store else { return }
        // Nothing is appended to a list the first read is still building. A workspace can be handed
        // a prompt the same moment its model is made, which starts the agent while the history is
        // still on its way in, and the read ends by putting the whole list on the model in one go:
        // a row appended here in the meantime would simply be overwritten.
        await loader.wait()
        let after = rows.map(\.seq).max() ?? -1
        let fresh = (try? await store.messages(sessionID: session.id, afterSeq: after)) ?? []
        for message in fresh { absorb(message) }
    }

    private func clearStreaming() {
        streamingText = ""
        streamingThinking = ""
        streamingToolName = nil
    }

    var isStreaming: Bool {
        !streamingText.isEmpty || !streamingThinking.isEmpty || streamingToolName != nil
    }

    private func notifyFinished(result: AgentResult) async {
        guard let store else { return }
        try? await store.touch(workspaceID: workspace.id, unread: app.selection.workspaceID != workspace.id)

        let model = app.model(for: workspace)
        await model.onTurnFinished()

        NotificationService.shared.turnFinished(
            workspace: workspace, result: result, wasCancelled: session.state == .cancelled
        )
    }
}

/// Small helpers that peek at a stored payload without decoding the whole event, used while
/// folding rows together. How a result went is read by `ToolResultSummary`, which lives in the
/// core so that telling a denial from a failure is covered by tests.
enum ParentProbe {
    static func parentToolUseID(_ payload: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return nil
        }
        return object["parent_tool_use_id"] as? String
    }
}
