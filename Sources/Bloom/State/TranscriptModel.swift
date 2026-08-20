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
    private(set) var isLoaded = false

    /// Text and thinking arriving live, before the completed block is persisted.
    private(set) var streamingText = ""
    private(set) var streamingThinking = ""
    private(set) var streamingToolName: String?
    private(set) var thinkingTokens = 0
    private(set) var statusLabel: String?

    var draft = ""
    var scrollTargetSeq: Int?

    private var runner: AgentRunner?
    private var pumpTask: Task<Void, Never>?
    private var indexByRefID: [String: Int] = [:]
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
        SwitchTrace.mark("transcript.read.start", workspace: workspace.id)
        let messages = (try? await store.messages(sessionID: session.id)) ?? []
        SwitchTrace.mark("transcript.read.done", workspace: workspace.id)
        rows = []
        indexByRefID = [:]
        for message in messages { absorb(message) }
        SwitchTrace.mark("transcript.rows.built", workspace: workspace.id)
        SwitchTrace.markOnScreen("transcript.rows.built", workspace: workspace.id)
        draft = (try? await store.draft(sessionID: session.id)) ?? ""
        isLoaded = true
    }

    /// Folds a stored message into the row list, pairing tool results onto their tool call.
    private func absorb(_ message: Message) {
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
        rows.append(row)
        if message.kind == .toolUse, let refID = message.refID {
            indexByRefID[refID] = rows.count - 1
        }
    }

    // MARK: - Unread

    var unreadCount: Int {
        rows.count { $0.seq > session.lastReadSeq }
    }

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

    func jumpToNextUnread() {
        scrollTargetSeq = firstUnreadSeq
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
        guard storedIsRunning != value else { return }
        storedIsRunning = value
        app.noteRunningChanged(workspaceID: workspace.id)
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
    private func ensureRunner() -> AgentRunner {
        let runner = self.runner ?? AgentRunner(
            workspacePath: workspace.path,
            session: session,
            store: app.store!
        )
        self.runner = runner
        if pumpTask == nil { startPump(on: runner) }
        return runner
    }

    private func startPump(on runner: AgentRunner) {
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

        case .hook, .rateLimit, .unknown:
            break
        }
    }

    /// Pulls anything the runner has persisted since the last row we hold. The runner is the
    /// single writer, so reading back from the store keeps one ordering and one source of truth.
    private func appendLatestMessages() async {
        guard let store else { return }
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
