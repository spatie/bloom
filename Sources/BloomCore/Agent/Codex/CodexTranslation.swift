import Foundation

/// Turns Codex's typed items into the vocabulary Bloom already stores and draws.
///
/// ## Why translate rather than add a second event type
///
/// A Codex chat is a chat. It has a transcript, a context gauge, unread counts, notifications, a
/// permission prompt and a session row, and every one of those already exists and works. Giving
/// Codex its own event type all the way to the view would fork all of it, so instead the protocol
/// is decoded honestly (`CodexEvent`) and then poured into `AgentEvent` here, in one place, with
/// the original item travelling inside the payload so nothing is lost.
///
/// ## The one real mismatch
///
/// Codex has no `tool_use`/`tool_result` pair. An item is created by `item/started` and **updated
/// in place** by `item/completed` under the same id. That maps onto the pair almost exactly:
/// `item/started` becomes the call and `item/completed` becomes its result, filed against the same
/// id. A transcript that appended both as rows would draw every command twice; a transcript that
/// pairs them draws what Bloom already draws for Claude Code, and the result row is where the
/// output, the exit code and a refusal live.
///
/// ## What is deliberately dropped
///
/// Sixty-odd of the seventy notifications say nothing a transcript should keep:
/// `mcpServer/startupStatus/updated` fires four times per turn, `fs/changed` fires per keystroke
/// in an editor. They reach `CodexEvent.unknown` with their method name intact and stop there.
/// `AgentEvent.unknown` is a stored row, so forwarding them would fill the transcript with noise
/// nobody can read.
public struct CodexTranslation: Sendable {
    /// What the chat is running, for the `system/init`-shaped event that opens a transcript.
    public struct Context: Sendable, Hashable {
        public var model: String
        public var cwd: String
        public var permissionMode: String
        public var version: String

        public init(model: String = "", cwd: String = "", permissionMode: String = "", version: String = "") {
            self.model = model
            self.cwd = cwd
            self.permissionMode = permissionMode
            self.version = version
        }
    }

    public var context: Context
    /// The running token figures, which arrive on their own notification rather than on the line
    /// that closes the turn. Held so the result event can carry them.
    public private(set) var usage: CodexTokenUsage = CodexTokenUsage()

    public init(context: Context = Context()) {
        self.context = context
    }

    // MARK: - Item names

    /// The name a Codex item is filed under.
    ///
    /// Codex's own words, not Claude Code's. `Shell` is not `Bash` and `ApplyPatch` is not `Edit`:
    /// they are different tools with different rules, and a permission grant reads back out of the
    /// database as the thing the user actually approved. The one exception is an MCP call, which
    /// both backends spell `mcp__server__tool`, because there it really is the same tool.
    public static func toolName(for item: CodexItem) -> String {
        switch item {
        case .commandExecution: "Shell"
        case .fileChange: "ApplyPatch"
        case .mcpToolCall(let call): "mcp__\(call.server)__\(call.tool)"
        case .webSearch: "WebSearch"
        case .plan: "Plan"
        case .subAgentActivity: "SubAgent"
        case .contextCompaction: "Compact"
        case .other(let type, _, _): "Codex.\(type)"
        case .userMessage, .agentMessage, .reasoning: ""
        }
    }

    /// The key the raw item is carried under, and the marker that says a row is a Codex one.
    ///
    /// A presenter has to know which vocabulary a row is in, and reading it off the payload rather
    /// than off the session means a transcript drawn from the database alone still knows, without
    /// a join and without a column that did not exist when the row was written.
    public static let itemKey = "codexItem"

    /// Whether this call came from Codex. What `TranscriptPresenter` switches on.
    public static func isCodexCall(_ input: JSONValue) -> Bool {
        input[itemKey] != nil
    }

    /// The item back out of a stored row, for a presenter.
    public static func item(in input: JSONValue) -> CodexItem? {
        guard let json = input[itemKey] else { return nil }
        return CodexItem.decode(json)
    }

    /// Whether an item is drawn as a call rather than as prose. Everything with a lifecycle is.
    public static func isCall(_ item: CodexItem) -> Bool {
        switch item {
        case .userMessage, .agentMessage, .reasoning: false
        default: true
        }
    }

    // MARK: - Calls

    /// The input object a call row is drawn from.
    ///
    /// The one field a collapsed row and a permission prompt both want is lifted to the top level
    /// under the name Bloom already looks for (`command`, `file_path`, `url`), so
    /// `PermissionAsk.subject` and `AgentToolUse.filePath` work on a Codex row without knowing
    /// anything about Codex. The whole item travels underneath for everything else.
    public static func input(for item: CodexItem) -> JSONValue {
        var members: [String: JSONValue] = [:]

        switch item {
        case .commandExecution(let run):
            members["command"] = .string(run.command)
            if !run.cwd.isEmpty { members["cwd"] = .string(run.cwd) }
        case .fileChange(let change):
            if let first = change.changes.first { members["file_path"] = .string(first.path) }
        case .mcpToolCall(let call):
            members["server"] = .string(call.server)
            members["tool"] = .string(call.tool)
        case .webSearch(let search):
            members["query"] = .string(search.query)
            if let url = search.url { members["url"] = .string(url) }
        case .plan(let plan):
            members["text"] = .string(plan.text)
        default:
            break
        }

        members[itemKey] = json(of: item)
        return .object(members)
    }

    /// The item as JSON, which for anything Bloom decoded means rebuilding it rather than keeping
    /// the notification envelope: the envelope carries thread and turn ids that the row already
    /// has, and an `.other` item kept its payload whole anyway.
    static func json(of item: CodexItem) -> JSONValue {
        switch item {
        case .other(_, _, let payload):
            return payload

        case .commandExecution(let run):
            return .object(omittingNil: [
                "type": .string("commandExecution"),
                "id": .string(run.id),
                "command": .string(run.command),
                "cwd": run.cwd.isEmpty ? nil : .string(run.cwd),
                "aggregatedOutput": run.aggregatedOutput.isEmpty ? nil : .string(run.aggregatedOutput),
                "exitCode": run.exitCode.map { .integer($0) },
                "durationMs": run.durationMS.map { .integer($0) },
                "status": .string(run.status.rawValue),
            ])

        case .fileChange(let change):
            return .object([
                "type": .string("fileChange"),
                "id": .string(change.id),
                "status": .string(change.status.rawValue),
                "changes": .array(change.changes.map { update in
                    .object(omittingNil: [
                        "path": .string(update.path),
                        "diff": .string(update.diff),
                        "kind": .object(omittingNil: [
                            "type": .string(update.kind.wireName),
                            "move_path": update.kind.movedTo.map { .string($0) },
                        ]),
                    ])
                }),
            ])

        case .mcpToolCall(let call):
            return .object(omittingNil: [
                "type": .string("mcpToolCall"),
                "id": .string(call.id),
                "server": .string(call.server),
                "tool": .string(call.tool),
                "arguments": call.arguments,
                "status": .string(call.status.rawValue),
                "error": call.errorMessage.map { .object(["message": .string($0)]) },
                "durationMs": call.durationMS.map { .integer($0) },
            ])

        case .webSearch(let search):
            return .object(omittingNil: [
                "type": .string("webSearch"),
                "id": .string(search.id),
                "query": .string(search.query),
                "action": .object(omittingNil: [
                    "type": .string(search.action),
                    "url": search.url.map { .string($0) },
                ]),
            ])

        case .plan(let plan):
            return .object([
                "type": .string("plan"), "id": .string(plan.id), "text": .string(plan.text),
            ])

        case .subAgentActivity(let activity):
            return .object([
                "type": .string("subAgentActivity"),
                "id": .string(activity.id),
                "agentPath": .string(activity.agentPath),
                "agentThreadId": .string(activity.agentThreadID),
                "kind": .string(activity.kind),
            ])

        case .contextCompaction(let id):
            return .object(["type": .string("contextCompaction"), "id": .string(id)])

        case .userMessage(let message):
            return .object([
                "type": .string("userMessage"),
                "id": .string(message.id),
                "text": .string(message.text),
            ])

        case .agentMessage(let message):
            return .object([
                "type": .string("agentMessage"),
                "id": .string(message.id),
                "text": .string(message.text),
            ])

        case .reasoning(let reasoning):
            return .object([
                "type": .string("reasoning"),
                "id": .string(reasoning.id),
                "summary": .array(reasoning.summary.map { .string($0) }),
                "content": .array(reasoning.content.map { .string($0) }),
            ])
        }
    }

    /// What a finished call put on screen: output for a command, the diff for a patch, the error
    /// for an MCP call that failed.
    public static func resultText(for item: CodexItem) -> String {
        switch item {
        case .commandExecution(let run):
            if !run.aggregatedOutput.isEmpty { return run.aggregatedOutput }
            guard let code = run.exitCode else { return "" }
            return code == 0 ? "" : "Exited \(code)"

        case .fileChange(let change):
            return change.changes.map(\.diff).joined(separator: "\n")

        case .mcpToolCall(let call):
            return call.errorMessage ?? ""

        case .plan(let plan):
            return plan.text

        case .webSearch(let search):
            return search.url ?? ""

        case .subAgentActivity(let activity):
            return "\(activity.agentPath) \(activity.kind)"

        default:
            return ""
        }
    }

    /// The status of a finished call, when it has one. `declined` is not a failure: nothing broke,
    /// somebody said no, and `ToolRefusal` is what draws that difference.
    public static func status(of item: CodexItem) -> CodexRunStatus {
        switch item {
        case .commandExecution(let run): run.status
        case .fileChange(let change): change.status
        case .mcpToolCall(let call): call.status
        default: .completed
        }
    }

    // MARK: - Envelopes

    /// The bytes a row is stored as.
    ///
    /// **In Claude Code's stream-json shape, on purpose.** A stored row is read back by
    /// `AgentEvent.decode(line:)`, which knows one vocabulary, so storing the JSON-RPC
    /// notification would give a transcript that drew perfectly while it was live and came back as
    /// a column of unknown rows after a restart. Writing the row in the vocabulary its reader
    /// speaks is what makes a Codex chat survive being closed and reopened, and it costs one
    /// envelope per event.
    ///
    /// The Codex item travels inside `input`, under `CodexTranslation.itemKey`, so nothing is lost
    /// on the way through and a presenter reading a row from the database still knows which
    /// vocabulary it is in.
    static func assistantLine(
        blocks: [JSONValue],
        messageID: String,
        model: String,
        usage: AgentUsage,
        sessionID: String
    ) -> Data {
        line(.object([
            "type": .string("assistant"),
            "session_id": .string(sessionID),
            "message": .object([
                "id": .string(messageID),
                "model": .string(model),
                "role": .string("assistant"),
                "content": .array(blocks),
                "usage": encode(usage),
            ]),
        ]))
    }

    static func toolResultLine(
        toolUseID: String,
        text: String,
        isError: Bool,
        refusalKind: String?,
        sessionID: String
    ) -> Data {
        var members: [String: JSONValue] = [
            "type": .string("user"),
            "session_id": .string(sessionID),
            "message": .object([
                "role": .string("user"),
                "content": .array([.object([
                    "type": .string("tool_result"),
                    "tool_use_id": .string(toolUseID),
                    "content": .string(text),
                    "is_error": .bool(isError),
                ])]),
            ]),
        ]
        // The array that separates a refused call from a broken one. Claude Code writes it beside
        // the message rather than inside the block, and `AgentEvent` reads it from there.
        if let refusalKind {
            members["tool_result_meta"] = .array([.object([
                "id": .string(toolUseID),
                "non_execution_kind": .string(refusalKind),
            ])])
        }
        return line(.object(members))
    }

    static func resultLine(
        subtype: String,
        isError: Bool,
        summary: String,
        durationMS: Int,
        usage: AgentUsage,
        model: String,
        sessionID: String
    ) -> Data {
        var result: [String: JSONValue] = [
            "type": .string("result"),
            "subtype": .string(subtype),
            "is_error": .bool(isError),
            "result": .string(summary),
            "duration_ms": .integer(durationMS),
            "num_turns": .integer(1),
            "session_id": .string(sessionID),
            "usage": encode(usage),
        ]
        // Where the context gauge reads the window from. Codex hands the figure over directly on
        // `thread/tokenUsage/updated`, which is one notification rather than Claude Code's two
        // separate lines, and it is put back in the place the existing reader looks.
        if usage.contextTokens > 0 {
            result["modelUsage"] = .object([
                model: .object(["contextWindow": .integer(usage.contextTokens)]),
            ])
        }
        return line(.object(result))
    }

    static func initLine(sessionID: String, context: Context) -> Data {
        line(.object([
            "type": .string("system"),
            "subtype": .string("init"),
            "session_id": .string(sessionID),
            "cwd": .string(context.cwd),
            "model": .string(context.model),
            "permissionMode": .string(context.permissionMode),
            "claude_code_version": .string(context.version),
            "agent_kind": .string(AgentKind.codex.rawValue),
        ]))
    }

    /// A turn that failed. The shape `AgentExit` reads: the sentence goes in `stderr`, because
    /// that is the field it classifies, and there is no exit status because nothing exited.
    static func errorLine(message: String) -> Data {
        line(.object([
            "type": .string("error"),
            "subtype": .string("codex"),
            "stderr": .string(message),
        ]))
    }

    static func rateLimitLine(_ payload: Data) -> Data {
        line(.object([
            "type": .string("rate_limit_event"),
            "codex": JSONValue.parse(payload) ?? .null,
        ]))
    }

    /// Tokens in the shape `AgentUsage.decode` reads. Cache figures are written as zero rather
    /// than as the Codex cached count: on this protocol the cached tokens are a subset of the
    /// input tokens, so adding them again would report a context window twice as full as it is.
    static func encode(_ usage: AgentUsage) -> JSONValue {
        .object([
            "input_tokens": .integer(usage.inputTokens),
            "output_tokens": .integer(usage.outputTokens),
            "cache_read_input_tokens": .integer(usage.cacheReadTokens),
            "cache_creation_input_tokens": .integer(usage.cacheCreationTokens),
            "output_tokens_details": .object(["thinking_tokens": .integer(usage.thinkingTokens)]),
        ])
    }

    static func line(_ json: JSONValue) -> Data {
        Data(json.compactJSON.utf8)
    }

    // MARK: - Translating

    /// One Codex event, as zero or more Bloom events.
    ///
    /// Mutating because two figures arrive on notifications of their own and are needed on a
    /// different one: the token usage, and the thread id.
    public mutating func translate(_ event: CodexEvent) -> [AgentEvent] {
        switch event {
        case .threadStarted(let threadID, _):
            return [.initialized(AgentInit(
                sessionID: threadID,
                cwd: context.cwd,
                model: context.model,
                permissionMode: context.permissionMode,
                version: context.version,
                raw: Self.initLine(sessionID: threadID, context: context)
            ))]

        case .itemStarted(let started):
            guard Self.isCall(started.item) else { return [] }
            let input = Self.input(for: started.item)
            let block = JSONValue.object([
                "type": .string("tool_use"),
                "id": .string(started.item.id),
                "name": .string(Self.toolName(for: started.item)),
                "input": input,
            ])
            return [.toolUse(AgentToolUse(
                id: started.item.id,
                name: Self.toolName(for: started.item),
                input: input,
                raw: Self.assistantLine(
                    blocks: [block],
                    messageID: started.item.id,
                    model: context.model,
                    usage: usage.agentUsage,
                    sessionID: started.threadID
                ),
                messageID: started.item.id,
                sessionID: started.threadID
            ))]

        case .itemCompleted(let completed):
            return completedEvents(completed)

        case .agentMessageDelta(let delta):
            return [.streamDelta(.text(delta.text))]

        case .reasoningDelta(let delta):
            return [.streamDelta(.thinking(delta.text))]

        case .tokenUsage(let value):
            usage = value
            return []

        case .rateLimits(let raw):
            return [.rateLimit(Self.rateLimitLine(raw))]

        case .threadStatus(let status):
            guard status.state == .active else { return [] }
            return [.status(status.isWaitingOnApproval ? "Waiting on you" : "Working")]

        case .turnCompleted(let turn):
            return [.result(result(for: turn))]

        case .turnError(let failure):
            // A failure the server is about to retry is not news. Drawing an error row for one
            // that then succeeds is the same lie as drawing a denial as a crash.
            guard !failure.willRetry else { return [] }
            return [.error(AgentError(
                message: failure.message,
                raw: Self.errorLine(message: failure.message)
            ))]

        case .closed(let reason):
            return [.error(AgentError(message: reason, raw: Self.errorLine(message: reason)))]

        // The turn starting, plan and command output deltas, and the sixty notifications nothing
        // draws. Deliberately nothing: see the note at the top of this file.
        case .turnStarted, .planDelta, .commandOutputDelta, .approval, .unknown:
            return []
        }
    }

    private func completedEvents(_ completed: CodexItemEvent) -> [AgentEvent] {
        switch completed.item {
        // The user's own words are written when they are sent, exactly as `AgentRunner` writes
        // them, so echoing the item back would file the prompt twice.
        case .userMessage:
            return []

        case .agentMessage(let message):
            guard !message.text.isEmpty else { return [] }
            return [.assistantText(AgentTextBlock(
                text: message.text,
                raw: Self.assistantLine(
                    blocks: [.object(["type": .string("text"), "text": .string(message.text)])],
                    messageID: message.id,
                    model: context.model,
                    usage: usage.agentUsage,
                    sessionID: completed.threadID
                ),
                messageID: message.id,
                model: context.model,
                usage: usage.agentUsage,
                sessionID: completed.threadID
            ))]

        case .reasoning(let reasoning):
            // An empty reasoning item is normal: the model reasoned and the summary was not
            // requested. A blank thinking row is worse than none.
            let text = reasoning.displayText
            guard !text.isEmpty else { return [] }
            return [.thinking(AgentTextBlock(
                text: text,
                raw: Self.assistantLine(
                    blocks: [.object(["type": .string("thinking"), "thinking": .string(text)])],
                    messageID: reasoning.id,
                    model: context.model,
                    usage: usage.agentUsage,
                    sessionID: completed.threadID
                ),
                messageID: reasoning.id,
                model: context.model,
                usage: usage.agentUsage,
                sessionID: completed.threadID
            ))]

        default:
            let status = Self.status(of: completed.item)
            let isError = status == .failed || status == .declined
            // `user-rejected` is the CLI's own word for a call somebody refused, and it is what
            // `ToolRefusal` reads. A declined patch is not a crash and must not be drawn as one.
            let refusalKind = status == .declined ? "user-rejected" : nil
            let text = Self.resultText(for: completed.item)
            return [.toolResult(AgentToolResult(
                toolUseID: completed.item.id,
                text: text,
                isError: isError,
                refusal: status == .declined ? .denied : nil,
                raw: Self.toolResultLine(
                    toolUseID: completed.item.id,
                    text: text,
                    isError: isError,
                    refusalKind: refusalKind,
                    sessionID: completed.threadID
                ),
                sessionID: completed.threadID
            ))]
        }
    }

    private func result(for turn: CodexTurn) -> AgentResult {
        let subtype = turn.status == .completed ? "success" : turn.status.rawValue
        let summary = turn.errorMessage ?? ""
        return AgentResult(
            usage: usage.agentUsage,
            summary: summary,
            isError: turn.status == .failed,
            subtype: subtype,
            durationMS: turn.durationMS ?? 0,
            numTurns: 1,
            stopReason: turn.status == .interrupted ? "interrupted" : nil,
            raw: Self.resultLine(
                subtype: subtype,
                isError: turn.status == .failed,
                summary: summary,
                durationMS: turn.durationMS ?? 0,
                usage: usage.agentUsage,
                model: context.model,
                sessionID: turn.threadID
            ),
            sessionID: turn.threadID
        )
    }
}

// MARK: - Helpers

extension CodexFileUpdate.Kind {
    /// The wire spelling, for putting a decoded change back the way it arrived.
    var wireName: String {
        switch self {
        case .add: "add"
        case .delete: "delete"
        case .update: "update"
        case .unknown(let raw): raw
        }
    }

    var movedTo: String? {
        if case .update(let path) = self { return path }
        return nil
    }

    /// The verb a row prints. `update` with a destination is a rename, which is a different thing
    /// to a person even though the protocol calls both an update.
    public var label: String {
        switch self {
        case .add: "Created"
        case .delete: "Deleted"
        case .update(let movedTo): movedTo == nil ? "Edited" : "Moved"
        case .unknown: "Changed"
        }
    }
}
