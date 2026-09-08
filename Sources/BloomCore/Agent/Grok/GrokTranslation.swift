import Foundation

/// Turns Grok's ACP updates into the vocabulary Bloom already stores and draws.
///
/// A Grok chat is a chat. It has a transcript, a context gauge, unread counts, notifications, a
/// permission prompt and a session row. Giving Grok its own event type all the way to the view
/// would fork all of it, so the protocol is decoded honestly (`GrokEvent`) and poured into
/// `AgentEvent` here, with the original tool call travelling inside the payload so nothing is lost.
///
/// Stored rows are written in Claude Code's stream-json shape, for the same reason Codex's are:
/// `AgentEvent.decode(line:)` knows one vocabulary, and a JSON-RPC notification stored as-is
/// would draw perfectly while live and come back as unknown rows after a restart.
public struct GrokTranslation: Sendable {
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
    public private(set) var usage = AgentUsage()
    public private(set) var sessionID = ""

    private var text = ""
    private var thought = ""
    private var tools: [String: GrokToolCall] = [:]
    private var textMessageID = ""
    private var thoughtMessageID = ""

    public init(context: Context = Context()) {
        self.context = context
    }

    /// The key the raw ACP tool call is carried under, and the marker that says a row is a Grok one.
    public static let itemKey = "grokItem"

    public static func isGrokCall(_ input: JSONValue) -> Bool {
        input[itemKey] != nil
    }

    /// The name a Grok tool is filed under in Bloom's existing presenters.
    ///
    /// Grok's own ids (`read_file`, `run_terminal_cmd`) are not Claude Code's, and
    /// `ToolPresenter` switches on Claude Code's. Mapping here, with the original travelling
    /// under `itemKey`, means a Read row still looks like a Read row without Grok growing a
    /// second presenter. An unmapped name is kept, so a new tool still has a fallback row.
    public static func toolName(for call: GrokToolCall) -> String {
        let raw = call.toolName.isEmpty ? call.title : call.toolName
        switch raw {
        case "read_file", "Read": return "Read"
        case "write_file", "Write": return "Write"
        case "search_replace", "str_replace", "Edit": return "Edit"
        case "run_terminal_cmd", "bash", "shell", "Bash": return "Bash"
        case "grep", "Grep": return "Grep"
        case "glob_file_search", "glob", "Glob": return "Glob"
        case "list_dir": return "Glob"
        case "web_search", "WebSearch": return "WebSearch"
        case "web_fetch", "WebFetch": return "WebFetch"
        case "todo_write", "TodoWrite": return "TodoWrite"
        case "spawn_subagent", "Agent", "Task": return "Task"
        default:
            if raw.hasPrefix("mcp__") { return raw }
            return raw.isEmpty ? "Grok.\(call.kind.isEmpty ? "tool" : call.kind)" : raw
        }
    }

    /// Lift Grok's `path` onto `file_path` so `PermissionAsk.subject` and `AgentToolUse.filePath`
    /// work without knowing anything about Grok. The whole ACP object travels underneath.
    public static func input(for call: GrokToolCall) -> JSONValue {
        var members = call.rawInput.objectValue ?? [:]
        if members["file_path"] == nil {
            if let path = members["path"] {
                members["file_path"] = path
            } else if !call.path.isEmpty {
                members["file_path"] = .string(call.path)
            }
        }
        if members["command"] == nil, let command = members["cmd"] {
            members["command"] = command
        }
        if members["query"] == nil, let query = members["search_term"] ?? members["pattern"] {
            members["query"] = query
        }
        members[itemKey] = call.json
        return .object(members)
    }

    // MARK: - Translating

    public mutating func translate(_ event: GrokEvent) -> [AgentEvent] {
        switch event {
        case .sessionReady(let session):
            sessionID = session.id
            if !session.currentModelID.isEmpty { context.model = session.currentModelID }
            return [.initialized(AgentInit(
                sessionID: session.id,
                cwd: context.cwd,
                model: context.model,
                permissionMode: context.permissionMode,
                agentKind: .grok,
                version: context.version,
                raw: Self.initLine(sessionID: session.id, context: context)
            ))]

        case .update(let update):
            if !update.sessionID.isEmpty { sessionID = update.sessionID }
            return updateEvents(update)

        case .promptCompleted(let result):
            if !result.sessionID.isEmpty { sessionID = result.sessionID }
            var events = flushOpenBlocks()
            events.append(.result(self.result(for: result)))
            tools.removeAll()
            return events

        case .closed(let reason):
            return [.error(AgentError(message: reason, raw: Self.errorLine(message: reason)))]

        case .permission, .unknown:
            return []
        }
    }

    private mutating func updateEvents(_ update: GrokSessionUpdate) -> [AgentEvent] {
        switch update.kind {
        case .text(let chunk):
            guard !chunk.isEmpty else { return [] }
            var events = flushThought()
            if text.isEmpty { textMessageID = UUID().uuidString }
            text += chunk
            events.append(.streamDelta(.text(chunk)))
            return events

        case .thought(let chunk):
            guard !chunk.isEmpty else { return [] }
            if thought.isEmpty { thoughtMessageID = UUID().uuidString }
            thought += chunk
            return [.streamDelta(.thinking(chunk))]

        case .toolCall(let call):
            var events = flushOpenBlocks()
            tools[call.id] = merged(call, onto: tools[call.id])
            let stored = tools[call.id] ?? call
            let input = Self.input(for: stored)
            let name = Self.toolName(for: stored)
            let block = JSONValue.object([
                "type": .string("tool_use"),
                "id": .string(stored.id),
                "name": .string(name),
                "input": input,
            ])
            events.append(.toolUse(AgentToolUse(
                id: stored.id,
                name: name,
                input: input,
                raw: Self.assistantLine(
                    blocks: [block],
                    messageID: stored.id,
                    model: context.model,
                    usage: usage,
                    sessionID: sessionID
                ),
                messageID: stored.id,
                sessionID: sessionID
            )))
            if stored.isFinished {
                events.append(contentsOf: toolResult(for: stored))
            }
            return events

        case .toolCallUpdate(let call):
            let stored = merged(call, onto: tools[call.id])
            tools[call.id] = stored
            guard stored.isFinished else { return [] }
            return toolResult(for: stored)

        case .usage(let used, let size):
            usage.inputTokens = used
            usage.contextTokens = size
            return []

        case .other:
            return []
        }
    }

    private mutating func flushOpenBlocks() -> [AgentEvent] {
        flushThought() + flushText()
    }

    private mutating func flushText() -> [AgentEvent] {
        let finished = text
        text = ""
        guard !finished.isEmpty else { return [] }
        let messageID = textMessageID
        textMessageID = ""
        return [.assistantText(AgentTextBlock(
            text: finished,
            raw: Self.assistantLine(
                blocks: [.object(["type": .string("text"), "text": .string(finished)])],
                messageID: messageID,
                model: context.model,
                usage: usage,
                sessionID: sessionID
            ),
            messageID: messageID,
            model: context.model,
            usage: usage,
            sessionID: sessionID
        ))]
    }

    private mutating func flushThought() -> [AgentEvent] {
        let finished = thought
        thought = ""
        guard !finished.isEmpty else { return [] }
        let messageID = thoughtMessageID
        thoughtMessageID = ""
        return [.thinking(AgentTextBlock(
            text: finished,
            raw: Self.assistantLine(
                blocks: [.object(["type": .string("thinking"), "thinking": .string(finished)])],
                messageID: messageID,
                model: context.model,
                usage: usage,
                sessionID: sessionID
            ),
            messageID: messageID,
            model: context.model,
            usage: usage,
            sessionID: sessionID
        ))]
    }

    private func toolResult(for call: GrokToolCall) -> [AgentEvent] {
        let text = call.contentText.isEmpty
            ? (call.rawOutput.stringValue ?? call.rawOutput.prettyPrinted)
            : call.contentText
        let display = text == "null" ? "" : text
        return [.toolResult(AgentToolResult(
            toolUseID: call.id,
            text: display,
            isError: call.isError,
            refusal: call.status == "cancelled" ? .denied : nil,
            raw: Self.toolResultLine(
                toolUseID: call.id,
                text: display,
                isError: call.isError,
                refusalKind: call.status == "cancelled" ? "user-rejected" : nil,
                sessionID: sessionID
            ),
            sessionID: sessionID
        ))]
    }

    private func merged(_ incoming: GrokToolCall, onto existing: GrokToolCall?) -> GrokToolCall {
        guard let existing else { return incoming }
        return GrokToolCall(
            id: incoming.id.isEmpty ? existing.id : incoming.id,
            title: incoming.title.isEmpty ? existing.title : incoming.title,
            kind: incoming.kind.isEmpty ? existing.kind : incoming.kind,
            status: incoming.status.isEmpty ? existing.status : incoming.status,
            toolName: incoming.toolName.isEmpty ? existing.toolName : incoming.toolName,
            rawInput: incoming.rawInput.objectValue?.isEmpty == false ? incoming.rawInput : existing.rawInput,
            rawOutput: incoming.rawOutput.isNull ? existing.rawOutput : incoming.rawOutput,
            contentText: incoming.contentText.isEmpty ? existing.contentText : incoming.contentText,
            path: incoming.path.isEmpty ? existing.path : incoming.path,
            json: incoming.json
        )
    }

    private func result(for prompt: GrokPromptResult) -> AgentResult {
        let subtype = prompt.wasCancelled ? "error_during_execution"
            : prompt.isError ? prompt.stopReason
            : "success"
        return AgentResult(
            usage: usage,
            summary: "",
            isError: prompt.isError,
            subtype: subtype,
            durationMS: 0,
            numTurns: 1,
            stopReason: prompt.stopReason,
            raw: Self.resultLine(
                subtype: subtype,
                isError: prompt.isError,
                summary: "",
                durationMS: 0,
                usage: usage,
                model: context.model,
                sessionID: sessionID
            ),
            sessionID: sessionID
        )
    }

    // MARK: - Envelopes

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
            "agent_kind": .string(AgentKind.grok.rawValue),
        ]))
    }

    static func errorLine(message: String) -> Data {
        line(.object([
            "type": .string("error"),
            "subtype": .string("grok"),
            "stderr": .string(message),
        ]))
    }

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
}
