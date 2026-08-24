import Foundation

// MARK: - Items

/// One entry in a Codex thread.
///
/// Codex has no `tool_use`/`tool_result` pair. Everything the agent does is a typed item with a
/// lifecycle: `item/started` when it appears, zero or more deltas, then `item/completed` carrying
/// the same id and the finished payload. So a transcript row is created once and updated in place,
/// rather than being closed by a second event that has to be matched to the first.
///
/// The eighteen types are the ones `ThreadItem` names in the generated schema. The ten Bloom will
/// draw are lifted into structs; the rest keep their JSON so a renderer written later has
/// everything, and so a type added by a future release lands in `.other` instead of being lost.
public enum CodexItem: Sendable, Hashable {
    case userMessage(CodexUserMessage)
    case agentMessage(CodexAgentMessage)
    case reasoning(CodexReasoning)
    case plan(CodexPlan)
    case commandExecution(CodexCommandExecution)
    case fileChange(CodexFileChange)
    case mcpToolCall(CodexMcpToolCall)
    case webSearch(CodexWebSearch)
    case subAgentActivity(CodexSubAgentActivity)
    case contextCompaction(id: String)
    /// A typed item with no bespoke reading yet: `dynamicToolCall`, `imageView`, `sleep`,
    /// `imageGeneration`, `enteredReviewMode`, `exitedReviewMode`, `hookPrompt`,
    /// `collabAgentToolCall`, and whatever the next release adds.
    case other(type: String, id: String, json: JSONValue)

    public var id: String {
        switch self {
        case .userMessage(let item): item.id
        case .agentMessage(let item): item.id
        case .reasoning(let item): item.id
        case .plan(let item): item.id
        case .commandExecution(let item): item.id
        case .fileChange(let item): item.id
        case .mcpToolCall(let item): item.id
        case .webSearch(let item): item.id
        case .subAgentActivity(let item): item.id
        case .contextCompaction(let id): id
        case .other(_, let id, _): id
        }
    }

    /// The wire name, which is what a presenter switches on and what a stored row records.
    public var typeName: String {
        switch self {
        case .userMessage: "userMessage"
        case .agentMessage: "agentMessage"
        case .reasoning: "reasoning"
        case .plan: "plan"
        case .commandExecution: "commandExecution"
        case .fileChange: "fileChange"
        case .mcpToolCall: "mcpToolCall"
        case .webSearch: "webSearch"
        case .subAgentActivity: "subAgentActivity"
        case .contextCompaction: "contextCompaction"
        case .other(let type, _, _): type
        }
    }

    public static func decode(_ json: JSONValue) -> CodexItem? {
        guard let type = json["type"]?.stringValue else { return nil }
        let id = json["id"]?.stringValue ?? ""

        switch type {
        case "userMessage":
            return .userMessage(CodexUserMessage(
                id: id,
                text: CodexUserMessage.renderText(json["content"]),
                imagePaths: CodexUserMessage.imagePaths(json["content"]),
                clientID: json["clientId"]?.stringValue
            ))

        case "agentMessage":
            return .agentMessage(CodexAgentMessage(
                id: id,
                text: json["text"]?.stringValue ?? "",
                phase: CodexMessagePhase(json["phase"]?.stringValue)
            ))

        case "reasoning":
            return .reasoning(CodexReasoning(
                id: id,
                summary: (json["summary"] ?? .null).stringArray,
                content: (json["content"] ?? .null).stringArray
            ))

        case "plan":
            return .plan(CodexPlan(id: id, text: json["text"]?.stringValue ?? ""))

        case "commandExecution":
            return .commandExecution(CodexCommandExecution(
                id: id,
                command: json["command"]?.stringValue ?? "",
                cwd: json["cwd"]?.stringValue ?? "",
                aggregatedOutput: json["aggregatedOutput"]?.stringValue ?? "",
                exitCode: json["exitCode"]?.intValue,
                durationMS: json["durationMs"]?.intValue,
                status: CodexRunStatus(json["status"]?.stringValue),
                processID: json["processId"]?.stringValue
            ))

        case "fileChange":
            return .fileChange(CodexFileChange(
                id: id,
                changes: (json["changes"]?.arrayValue ?? []).compactMap(CodexFileUpdate.decode),
                status: CodexRunStatus(json["status"]?.stringValue)
            ))

        case "mcpToolCall":
            return .mcpToolCall(CodexMcpToolCall(
                id: id,
                server: json["server"]?.stringValue ?? "",
                tool: json["tool"]?.stringValue ?? "",
                arguments: json["arguments"] ?? .null,
                status: CodexRunStatus(json["status"]?.stringValue),
                errorMessage: json["error"]?["message"]?.stringValue,
                durationMS: json["durationMs"]?.intValue
            ))

        case "webSearch":
            return .webSearch(CodexWebSearch(
                id: id,
                query: json["query"]?.stringValue ?? "",
                action: json["action"]?["type"]?.stringValue ?? "",
                url: json["action"]?["url"]?.stringValue
            ))

        case "subAgentActivity":
            return .subAgentActivity(CodexSubAgentActivity(
                id: id,
                agentPath: json["agentPath"]?.stringValue ?? "",
                agentThreadID: json["agentThreadId"]?.stringValue ?? "",
                kind: json["kind"]?.stringValue ?? ""
            ))

        case "contextCompaction":
            return .contextCompaction(id: id)

        default:
            return .other(type: type, id: id, json: json)
        }
    }
}

/// Whether an assistant message is narration on the way to an answer, or the answer.
///
/// Codex sends several `agentMessage` items in one turn: the preamble before a command runs is one
/// item, the final reply another. The schema warns that providers do not set this consistently, so
/// `.unknown` is a real state and must never be read as "not the answer".
public enum CodexMessagePhase: String, Sendable, Hashable {
    case commentary
    case finalAnswer
    case unknown

    init(_ raw: String?) {
        switch raw {
        case "commentary": self = .commentary
        case "final_answer": self = .finalAnswer
        default: self = .unknown
        }
    }
}

/// Shared by `commandExecution`, `fileChange` and `mcpToolCall`, which use the same four words.
public enum CodexRunStatus: String, Sendable, Hashable {
    case inProgress
    case completed
    case failed
    /// The user said no. Distinct from failed, and the state a refused approval leaves behind.
    case declined
    case unknown

    init(_ raw: String?) {
        self = raw.flatMap(CodexRunStatus.init(rawValue:)) ?? .unknown
    }
}

public struct CodexUserMessage: Sendable, Hashable {
    public let id: String
    public let text: String
    /// Attachments arrive as `localImage` entries carrying a path, which is exactly the shape
    /// Bloom's own attachment drafts already produce, so nothing about them has to change.
    public let imagePaths: [String]
    public let clientID: String?

    public init(id: String, text: String, imagePaths: [String] = [], clientID: String? = nil) {
        self.id = id
        self.text = text
        self.imagePaths = imagePaths
        self.clientID = clientID
    }

    static func renderText(_ content: JSONValue?) -> String {
        (content?.arrayValue ?? [])
            .filter { $0["type"]?.stringValue == "text" }
            .compactMap { $0["text"]?.stringValue }
            .joined(separator: "\n")
    }

    static func imagePaths(_ content: JSONValue?) -> [String] {
        (content?.arrayValue ?? []).compactMap { entry in
            switch entry["type"]?.stringValue {
            case "localImage": entry["path"]?.stringValue
            case "image": entry["url"]?.stringValue
            default: nil
            }
        }
    }
}

public struct CodexAgentMessage: Sendable, Hashable {
    public let id: String
    public let text: String
    public let phase: CodexMessagePhase

    public init(id: String, text: String, phase: CodexMessagePhase = .unknown) {
        self.id = id
        self.text = text
        self.phase = phase
    }
}

/// Codex sends reasoning as a summary and, when the model is configured to show it, the text.
/// Both are arrays of parts rather than one string.
public struct CodexReasoning: Sendable, Hashable {
    public let id: String
    public let summary: [String]
    public let content: [String]

    public init(id: String, summary: [String] = [], content: [String] = []) {
        self.id = id
        self.summary = summary
        self.content = content
    }

    /// What a thinking row shows: the summary when there is one, the raw text otherwise.
    public var displayText: String {
        let parts = summary.isEmpty ? content : summary
        return parts.joined(separator: "\n\n")
    }
}

public struct CodexPlan: Sendable, Hashable {
    public let id: String
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

public struct CodexCommandExecution: Sendable, Hashable {
    public let id: String
    public let command: String
    public let cwd: String
    public let aggregatedOutput: String
    public let exitCode: Int?
    public let durationMS: Int?
    public let status: CodexRunStatus
    public let processID: String?

    public init(
        id: String,
        command: String,
        cwd: String = "",
        aggregatedOutput: String = "",
        exitCode: Int? = nil,
        durationMS: Int? = nil,
        status: CodexRunStatus = .unknown,
        processID: String? = nil
    ) {
        self.id = id
        self.command = command
        self.cwd = cwd
        self.aggregatedOutput = aggregatedOutput
        self.exitCode = exitCode
        self.durationMS = durationMS
        self.status = status
        self.processID = processID
    }
}

public struct CodexFileUpdate: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case add
        case delete
        case update(movedTo: String?)
        case unknown(String)
    }

    public let path: String
    /// **Not always a diff**, which is the trap in the field's name. Measured against the real
    /// server:
    ///
    ///   * `update` carries a unified diff **hunk**: `@@ -1,3 +1,3 @@` and then the context and
    ///     the changed lines. No `---`/`+++` file headers, so it is a fragment rather than a whole
    ///     patch.
    ///   * `add` carries the **whole new file**, verbatim, with no diff markers at all. A new file
    ///     holding `hi` arrives as `"hi\n"`, and anything counting `+` lines in it counts nothing.
    ///   * `delete` is presumed symmetrical and has not been observed, so it is treated as content
    ///     rather than as a diff and `removedLines` says so.
    public let diff: String
    public let kind: Kind

    public init(path: String, diff: String, kind: Kind) {
        self.path = path
        self.diff = diff
        self.kind = kind
    }

    /// How many lines this change adds, whichever shape the payload is in.
    public var addedLines: Int {
        switch kind {
        case .add: Self.lineCount(diff)
        case .delete: 0
        case .update, .unknown: Self.hunkCount(diff, marker: "+")
        }
    }

    public var removedLines: Int {
        switch kind {
        case .add: 0
        case .delete: Self.lineCount(diff)
        case .update, .unknown: Self.hunkCount(diff, marker: "-")
        }
    }

    /// Lines of content. A trailing newline ends the last line rather than starting an empty one,
    /// which is what makes a one-line file count as one.
    static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var trimmed = text
        if trimmed.hasSuffix("\n") { trimmed.removeLast() }
        return trimmed.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// Changed lines in a hunk. `---` and `+++` are file headers rather than content: the observed
    /// hunks carry none, and counting them would add one of each per file if a future release did.
    static func hunkCount(_ diff: String, marker: Character) -> Int {
        diff.split(separator: "\n", omittingEmptySubsequences: false).count { line in
            guard line.first == marker else { return false }
            return !line.hasPrefix("+++") && !line.hasPrefix("---")
        }
    }

    static func decode(_ json: JSONValue) -> CodexFileUpdate? {
        guard let path = json["path"]?.stringValue else { return nil }
        let kind: Kind = switch json["kind"]?["type"]?.stringValue {
        case "add": .add
        case "delete": .delete
        case "update": .update(movedTo: json["kind"]?["move_path"]?.stringValue)
        case let other?: .unknown(other)
        case nil: .unknown("")
        }
        return CodexFileUpdate(path: path, diff: json["diff"]?.stringValue ?? "", kind: kind)
    }
}

public struct CodexFileChange: Sendable, Hashable {
    public let id: String
    public let changes: [CodexFileUpdate]
    public let status: CodexRunStatus

    public init(id: String, changes: [CodexFileUpdate], status: CodexRunStatus = .unknown) {
        self.id = id
        self.changes = changes
        self.status = status
    }
}

public struct CodexMcpToolCall: Sendable, Hashable {
    public let id: String
    public let server: String
    public let tool: String
    public let arguments: JSONValue
    public let status: CodexRunStatus
    public let errorMessage: String?
    public let durationMS: Int?

    public init(
        id: String,
        server: String,
        tool: String,
        arguments: JSONValue = .null,
        status: CodexRunStatus = .unknown,
        errorMessage: String? = nil,
        durationMS: Int? = nil
    ) {
        self.id = id
        self.server = server
        self.tool = tool
        self.arguments = arguments
        self.status = status
        self.errorMessage = errorMessage
        self.durationMS = durationMS
    }
}

public struct CodexWebSearch: Sendable, Hashable {
    public let id: String
    public let query: String
    /// `search`, `openPage` or `findInPage`.
    public let action: String
    public let url: String?

    public init(id: String, query: String, action: String = "", url: String? = nil) {
        self.id = id
        self.query = query
        self.action = action
        self.url = url
    }
}

public struct CodexSubAgentActivity: Sendable, Hashable {
    public let id: String
    public let agentPath: String
    public let agentThreadID: String
    /// `started`, `interacted` or `interrupted`.
    public let kind: String

    public init(id: String, agentPath: String, agentThreadID: String, kind: String) {
        self.id = id
        self.agentPath = agentPath
        self.agentThreadID = agentThreadID
        self.kind = kind
    }
}

// MARK: - Envelopes

/// An item plus which thread and turn it belongs to. Both ids travel on every item notification,
/// and a Bloom row needs them: one app-server connection can carry several threads.
public struct CodexItemEvent: Sendable, Hashable {
    public let item: CodexItem
    public let threadID: String
    public let turnID: String
    public let raw: Data

    public init(item: CodexItem, threadID: String, turnID: String, raw: Data = Data()) {
        self.item = item
        self.threadID = threadID
        self.turnID = turnID
        self.raw = raw
    }
}

/// A slice of text arriving as the model produces it. The finished item follows behind it, exactly
/// as `stream_event` and `assistant` do on the Claude Code side, so a delta is for live drawing
/// and is never the record.
public struct CodexTextDelta: Sendable, Hashable {
    public let itemID: String
    public let threadID: String
    public let turnID: String
    public let text: String

    public init(itemID: String, threadID: String, turnID: String, text: String) {
        self.itemID = itemID
        self.threadID = threadID
        self.turnID = turnID
        self.text = text
    }
}

public struct CodexTurn: Sendable, Hashable {
    public enum Status: String, Sendable, Hashable {
        case inProgress
        case completed
        case interrupted
        case failed
        case unknown
    }

    public let id: String
    public let threadID: String
    public let status: Status
    public let items: [CodexItem]
    public let errorMessage: String?
    public let durationMS: Int?
    public let raw: Data

    public init(
        id: String,
        threadID: String,
        status: Status,
        items: [CodexItem] = [],
        errorMessage: String? = nil,
        durationMS: Int? = nil,
        raw: Data = Data()
    ) {
        self.id = id
        self.threadID = threadID
        self.status = status
        self.items = items
        self.errorMessage = errorMessage
        self.durationMS = durationMS
        self.raw = raw
    }

    public var succeeded: Bool { status == .completed }

    static func decode(_ json: JSONValue, threadID: String, raw: Data) -> CodexTurn {
        CodexTurn(
            id: json["id"]?.stringValue ?? "",
            threadID: threadID,
            status: Status(rawValue: json["status"]?.stringValue ?? "") ?? .unknown,
            items: (json["items"]?.arrayValue ?? []).compactMap(CodexItem.decode),
            errorMessage: json["error"]?["message"]?.stringValue,
            durationMS: json["durationMs"]?.intValue,
            raw: raw
        )
    }
}

/// What the thread is doing, which is what a busy indicator reads.
///
/// `waitingOnApproval` arrives as an active flag rather than a state of its own, and it is the one
/// that tells a sidebar the difference between "working" and "waiting for you".
public struct CodexThreadStatus: Sendable, Hashable {
    public enum State: String, Sendable, Hashable {
        case notLoaded
        case idle
        case active
        case systemError
        case unknown
    }

    public let threadID: String
    public let state: State
    public let activeFlags: [String]

    public init(threadID: String, state: State, activeFlags: [String] = []) {
        self.threadID = threadID
        self.state = state
        self.activeFlags = activeFlags
    }

    public var isWaitingOnApproval: Bool { activeFlags.contains("waitingOnApproval") }
    public var isBusy: Bool { state == .active }
}

/// Codex reports tokens and nothing else. There is no price on this wire, so a Codex session's
/// `costUSD` stays zero and the inspector has to say tokens rather than dollars.
public struct CodexTokenUsage: Sendable, Hashable {
    public let threadID: String
    public let turnID: String
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let cacheWriteInputTokens: Int
    public let outputTokens: Int
    public let reasoningOutputTokens: Int
    public let totalTokens: Int
    /// The window the model is working in, when the server knows it. This is the denominator the
    /// context gauge needs, and Codex hands it over directly rather than per model as Claude does.
    public let contextWindow: Int

    public init(
        threadID: String = "",
        turnID: String = "",
        inputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        cacheWriteInputTokens: Int = 0,
        outputTokens: Int = 0,
        reasoningOutputTokens: Int = 0,
        totalTokens: Int = 0,
        contextWindow: Int = 0
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
        self.contextWindow = contextWindow
    }

    /// The `total` breakdown, which is the running figure for the whole thread. `last` is the same
    /// shape for the most recent request and is what a per-turn readout would use.
    static func decode(_ json: JSONValue, threadID: String, turnID: String, key: String) -> CodexTokenUsage {
        let breakdown = json[key] ?? .object([:])
        return CodexTokenUsage(
            threadID: threadID,
            turnID: turnID,
            inputTokens: breakdown["inputTokens"]?.intValue ?? 0,
            cachedInputTokens: breakdown["cachedInputTokens"]?.intValue ?? 0,
            cacheWriteInputTokens: breakdown["cacheWriteInputTokens"]?.intValue ?? 0,
            outputTokens: breakdown["outputTokens"]?.intValue ?? 0,
            reasoningOutputTokens: breakdown["reasoningOutputTokens"]?.intValue ?? 0,
            totalTokens: breakdown["totalTokens"]?.intValue ?? 0,
            contextWindow: json["modelContextWindow"]?.intValue ?? 0
        )
    }

    /// Poured into the shape the rest of Bloom already stores and draws.
    ///
    /// `cachedInputTokens` is a subset of `inputTokens` on this protocol, not a sibling of it, so
    /// it is not added again: `AgentUsage.contextUsedTokens` sums its three input fields, and
    /// double counting the cache would report a window twice as full as it is.
    public var agentUsage: AgentUsage {
        AgentUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            thinkingTokens: reasoningOutputTokens,
            costUSD: 0,
            contextTokens: contextWindow
        )
    }
}

/// A turn that failed, as opposed to one the user stopped. `willRetry` matters: the server retries
/// some failures itself, and drawing an error row for one that is about to succeed is noise.
public struct CodexTurnError: Sendable, Hashable {
    public let threadID: String
    public let turnID: String
    public let message: String
    public let willRetry: Bool
    public let raw: Data

    public init(threadID: String, turnID: String, message: String, willRetry: Bool, raw: Data = Data()) {
        self.threadID = threadID
        self.turnID = turnID
        self.message = message
        self.willRetry = willRetry
        self.raw = raw
    }
}

// MARK: - Events

/// One thing the server said, in the vocabulary Bloom's transcript can eventually draw.
///
/// Only the notifications a session needs are lifted out. The other sixty or so, from
/// `fs/changed` to `thread/realtime/sdp`, stay whole in `.unknown` with their method name, so
/// nothing is silently dropped and adding one later is a case rather than a protocol change.
public enum CodexEvent: Sendable {
    case threadStarted(threadID: String, raw: Data)
    case threadStatus(CodexThreadStatus)
    case turnStarted(CodexTurn)
    case turnCompleted(CodexTurn)
    case itemStarted(CodexItemEvent)
    case itemCompleted(CodexItemEvent)
    case agentMessageDelta(CodexTextDelta)
    case reasoningDelta(CodexTextDelta)
    case planDelta(CodexTextDelta)
    case commandOutputDelta(CodexTextDelta)
    case tokenUsage(CodexTokenUsage)
    case rateLimits(Data)
    /// A question with the turn held open until it is answered. The id is what the answer is
    /// addressed to, and it is the server's own numbering, not Bloom's.
    case approval(CodexApprovalRequest)
    case turnError(CodexTurnError)
    /// The connection ended. Synthesised, never sent by the server.
    case closed(reason: String)
    case unknown(method: String, raw: Data)

    public var raw: Data {
        switch self {
        case .threadStarted(_, let raw): raw
        case .turnStarted(let turn), .turnCompleted(let turn): turn.raw
        case .itemStarted(let event), .itemCompleted(let event): event.raw
        case .approval(let request): request.raw
        case .turnError(let error): error.raw
        case .rateLimits(let raw): raw
        case .unknown(_, let raw): raw
        case .threadStatus, .agentMessageDelta, .reasoningDelta, .planDelta, .commandOutputDelta,
             .tokenUsage, .closed:
            Data()
        }
    }

    /// The thread the event is about, so one connection can carry more than one.
    public var threadID: String? {
        switch self {
        case .threadStarted(let id, _): id
        case .threadStatus(let status): status.threadID
        case .turnStarted(let turn), .turnCompleted(let turn): turn.threadID
        case .itemStarted(let event), .itemCompleted(let event): event.threadID
        case .agentMessageDelta(let delta), .reasoningDelta(let delta),
             .planDelta(let delta), .commandOutputDelta(let delta):
            delta.threadID
        case .tokenUsage(let usage): usage.threadID
        case .approval(let request): request.threadID
        case .turnError(let error): error.threadID
        case .rateLimits, .closed, .unknown: nil
        }
    }

    /// Whether this belongs in the stored transcript. Deltas do not: the item behind them carries
    /// the finished text, and storing both would write the reply twice.
    public var isTranscriptRow: Bool {
        switch self {
        case .agentMessageDelta, .reasoningDelta, .planDelta, .commandOutputDelta,
             .threadStatus, .tokenUsage, .threadStarted:
            false
        default: true
        }
    }

    // MARK: Decoding

    public static func decode(_ notification: CodexServerNotification) -> CodexEvent {
        let params = notification.params
        let raw = notification.raw
        let threadID = params["threadId"]?.stringValue ?? ""
        let turnID = params["turnId"]?.stringValue ?? ""

        switch notification.method {
        case "thread/started":
            return .threadStarted(
                threadID: params["thread"]?["id"]?.stringValue ?? threadID,
                raw: raw
            )

        case "thread/status/changed":
            let status = params["status"] ?? .object([:])
            return .threadStatus(CodexThreadStatus(
                threadID: threadID,
                state: CodexThreadStatus.State(rawValue: status["type"]?.stringValue ?? "") ?? .unknown,
                activeFlags: (status["activeFlags"] ?? .null).stringArray
            ))

        case "turn/started":
            return .turnStarted(CodexTurn.decode(params["turn"] ?? .null, threadID: threadID, raw: raw))

        case "turn/completed":
            return .turnCompleted(CodexTurn.decode(params["turn"] ?? .null, threadID: threadID, raw: raw))

        case "item/started", "item/completed":
            guard let item = CodexItem.decode(params["item"] ?? .null) else {
                return .unknown(method: notification.method, raw: raw)
            }
            let event = CodexItemEvent(item: item, threadID: threadID, turnID: turnID, raw: raw)
            return notification.method == "item/started" ? .itemStarted(event) : .itemCompleted(event)

        case "item/agentMessage/delta":
            return .agentMessageDelta(delta(params, text: params["delta"]?.stringValue))

        // Two spellings, because a reasoning item has a summary and a body and the server streams
        // them on separate methods.
        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            return .reasoningDelta(delta(params, text: params["delta"]?.stringValue))

        case "item/plan/delta":
            return .planDelta(delta(params, text: params["delta"]?.stringValue))

        // The item's own output stream, verified against the generated schema: a plain string
        // named `delta`, exactly like the message and reasoning ones. The similarly named
        // `command/exec/outputDelta` belongs to the standalone terminal API and is not this.
        case "item/commandExecution/outputDelta", "item/fileChange/outputDelta":
            return .commandOutputDelta(delta(params, text: params["delta"]?.stringValue))

        case "thread/tokenUsage/updated":
            return .tokenUsage(CodexTokenUsage.decode(
                params["tokenUsage"] ?? .null,
                threadID: threadID,
                turnID: turnID,
                key: "total"
            ))

        case "account/rateLimits/updated":
            return .rateLimits(raw)

        case "error":
            return .turnError(CodexTurnError(
                threadID: threadID,
                turnID: turnID,
                message: params["error"]?["message"]?.stringValue ?? "",
                willRetry: params["willRetry"]?.boolValue ?? false,
                raw: raw
            ))

        default:
            return .unknown(method: notification.method, raw: raw)
        }
    }

    private static func delta(_ params: JSONValue, text: String?) -> CodexTextDelta {
        CodexTextDelta(
            itemID: params["itemId"]?.stringValue ?? "",
            threadID: params["threadId"]?.stringValue ?? "",
            turnID: params["turnId"]?.stringValue ?? "",
            text: text ?? ""
        )
    }
}

// MARK: - Approvals

/// One of the five questions the server can ask, held open until Bloom answers it.
///
/// **None of Claude Code's rule grammar exists here.** There is no `permission-rule`, no allow
/// list to append to and no `--permission-prompt-tool`: approvals are a property of the connection
/// and arrive as JSON-RPC requests. What Codex has instead is `acceptForSession`, which asks the
/// server to remember rather than asking Bloom to.
public struct CodexApprovalRequest: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case commandExecution
        case fileChange
        case permissions
        case mcpElicitation
        case toolUserInput

        init?(method: String) {
            switch method {
            case "item/commandExecution/requestApproval": self = .commandExecution
            case "item/fileChange/requestApproval": self = .fileChange
            case "item/permissions/requestApproval": self = .permissions
            case "mcpServer/elicitation/request": self = .mcpElicitation
            case "item/tool/requestUserInput": self = .toolUserInput
            default: return nil
            }
        }
    }

    public let id: CodexRequestID
    public let kind: Kind
    public let threadID: String
    public let turnID: String
    /// The item the question is about. A `fileChange` approval carries no diff of its own: the
    /// `item/started` that came just before it does, and this is what joins the two.
    public let itemID: String
    public let params: JSONValue
    public let raw: Data

    public init(
        id: CodexRequestID,
        kind: Kind,
        threadID: String,
        turnID: String,
        itemID: String,
        params: JSONValue,
        raw: Data = Data()
    ) {
        self.id = id
        self.kind = kind
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.params = params
        self.raw = raw
    }

    public static func decode(_ request: CodexServerRequest) -> CodexApprovalRequest? {
        guard let kind = Kind(method: request.method) else { return nil }
        return CodexApprovalRequest(
            id: request.id,
            kind: kind,
            threadID: request.params["threadId"]?.stringValue ?? "",
            turnID: request.params["turnId"]?.stringValue ?? "",
            itemID: request.params["itemId"]?.stringValue ?? "",
            params: request.params,
            raw: request.raw
        )
    }

    /// The command a `commandExecution` question is about, for the prompt's headline.
    public var command: String? { params["command"]?.stringValue }
}

/// What a person said about one question.
///
/// Four words, and each of the five request kinds spells them differently on the wire, which is
/// why the JSON body is built here rather than at the call site. `acceptForSession` is Codex's own
/// idea of "do not ask again": the server keeps the grant for the rest of the session, so unlike
/// Claude Code there is no rule for Bloom to store and replay.
public enum CodexApprovalDecision: String, Sendable, Hashable, CaseIterable {
    case accept
    case acceptForSession
    /// No, and the turn carries on so the agent can try something else.
    case decline
    /// No, and stop the turn now.
    case cancel

    /// The `result` for one answer, in the shape that request kind's response schema requires.
    ///
    /// `permissions` is the one that cannot be answered generically: its response is a granted
    /// permission profile rather than a word, so approving one is left to the permission work and
    /// only a refusal is expressible here. An empty profile is a refusal that grants nothing.
    public func result(for kind: CodexApprovalRequest.Kind) -> JSONValue {
        switch kind {
        case .commandExecution, .fileChange:
            return .object(["decision": .string(rawValue)])

        case .mcpElicitation:
            // The elicitation vocabulary has no session-wide accept.
            let action = self == .acceptForSession ? Self.accept : self
            return .object(["action": .string(action == .cancel ? "cancel" : action.rawValue)])

        case .toolUserInput:
            return .object(["answers": .object([:])])

        case .permissions:
            return .object([
                "permissions": .object([:]),
                "scope": .string(self == .acceptForSession ? "session" : "turn"),
            ])
        }
    }
}
