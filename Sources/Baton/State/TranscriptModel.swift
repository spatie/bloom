import SwiftUI
import Observation
import BatonCore

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
    private(set) var isRunning = false
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

    init(session: Session, workspace: Workspace, app: AppModel) {
        self.session = session
        self.workspace = workspace
        self.app = app
    }

    private var store: Store? { app.store }

    // MARK: - Loading

    func load() async {
        guard let store, !isLoaded else { return }
        let messages = (try? await store.messages(sessionID: session.id)) ?? []
        rows = []
        indexByRefID = [:]
        for message in messages { absorb(message) }
        draft = (try? await store.draft(sessionID: session.id)) ?? ""
        isLoaded = true
    }

    /// Folds a stored message into the row list, pairing tool results onto their tool call.
    private func absorb(_ message: Message) {
        if message.kind == .toolResult, let refID = message.refID,
           let index = indexByRefID[refID] {
            rows[index].resultPayload = message.payload
            rows[index].isError = ToolResultProbe.isError(message.payload)
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
        isRunning = true
        statusLabel = "Starting"

        do {
            try await runner.send(body)
        } catch {
            isRunning = false
            statusLabel = nil
            app.alert = BatonAlert(title: "Could not start the agent", message: "\(error)")
        }
    }

    func saveDraft() async {
        guard let store else { return }
        try? await store.saveDraft(sessionID: session.id, body: draft)
    }

    func stop() {
        runner?.cancelNow()
        pumpTask?.cancel()
        pumpTask = nil
        isRunning = false
        statusLabel = nil
        clearStreaming()
    }

    /// Starts the runner and the event pump on first use.
    private func ensureRunner() -> AgentRunner {
        if let runner { return runner }
        let runner = AgentRunner(
            workspacePath: workspace.path,
            session: session,
            store: app.store!
        )
        self.runner = runner
        pumpTask = Task { [weak self] in
            for await event in runner.events {
                guard let self else { return }
                await self.handle(event)
            }
        }
        return runner
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

        case .assistantText, .thinking, .toolUse, .toolResult, .error:
            clearStreaming()
            await appendLatestMessages()

        case .result(let result):
            clearStreaming()
            await appendLatestMessages()
            isRunning = false
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

        if app.selection.workspaceID != workspace.id {
            Notifications.post(
                title: workspace.name,
                body: result.summary.isEmpty ? "The agent finished." : result.summary,
                workspaceID: workspace.id
            )
        }
    }
}

/// Small helpers that peek at a stored payload without decoding the whole event, used while
/// folding rows together.
enum ToolResultProbe {
    static func isError(_ payload: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let message = object["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return false }
        return content.contains { ($0["is_error"] as? Bool) == true }
    }
}

enum ParentProbe {
    static func parentToolUseID(_ payload: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return nil
        }
        return object["parent_tool_use_id"] as? String
    }
}
