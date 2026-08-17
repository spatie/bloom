import Foundation

// MARK: - JSONValue

/// A closed representation of any JSON document.
///
/// Tool input is arbitrary JSON that Baton neither controls nor fully understands, so it has to
/// survive a round trip untouched. Modelling it as an enum rather than `Any` keeps it `Sendable`,
/// keeps it out of the dynamic-cast business, and lets a renderer added later dig into a payload
/// that was never decoded into a named type.
public enum JSONValue: Sendable, Hashable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
        if let value = try? container.decode([String: JSONValue].self) { self = .object(value); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Parse one JSON document. Returns nil rather than throwing, because every caller in Baton
    /// is on a path that must never abort the stream.
    public static func parse(_ data: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    public static func parse(_ text: String) -> JSONValue? {
        parse(Data(text.utf8))
    }

    // MARK: Accessors

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        guard case .number(let value) = self, value.isFinite else { return nil }
        return Int(value)
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self, let value = object[key], !value.isNull else { return nil }
        return value
    }

    public subscript(index: Int) -> JSONValue? {
        guard case .array(let array) = self, array.indices.contains(index) else { return nil }
        return array[index]
    }

    /// Strings out of a `[JSONValue]`, skipping anything that is not a string. Used for the tool
    /// and slash command lists on the init event.
    public var stringArray: [String] {
        (arrayValue ?? []).compactMap(\.stringValue)
    }

    /// Human-readable JSON, for showing a tool input that has no bespoke renderer yet.
    public var prettyPrinted: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Envelope

/// The fields every line of the stream carries, plus the untouched bytes it arrived as.
///
/// Baton stores the raw JSON for every transcript row so a renderer written a year from now can
/// show detail that nobody thought to decode today.
public struct AgentEnvelope: Sendable, Hashable {
    public let raw: Data
    public let type: String
    public let subtype: String?
    public let uuid: String?
    public let sessionID: String?
    public let parentToolUseID: String?

    public init(
        raw: Data,
        type: String,
        subtype: String? = nil,
        uuid: String? = nil,
        sessionID: String? = nil,
        parentToolUseID: String? = nil
    ) {
        self.raw = raw
        self.type = type
        self.subtype = subtype
        self.uuid = uuid
        self.sessionID = sessionID
        self.parentToolUseID = parentToolUseID
    }

    /// A subagent (the Agent tool) tags everything it emits with the tool use that spawned it,
    /// so the UI can indent those rows instead of mixing them into the main flow.
    public var isFromSubagent: Bool { parentToolUseID != nil }
}

// MARK: - Payloads

/// Everything the first line of a session binds: which agent session to resume, which model
/// answered, and what it was allowed to do.
public struct AgentInit: Sendable, Hashable {
    public let sessionID: String
    public let cwd: String
    public let model: String
    public let permissionMode: String
    public let outputStyle: String
    public let version: String
    public let tools: [String]
    public let slashCommands: [String]
    public let agents: [String]
}

public struct AgentText: Sendable, Hashable {
    public let text: String
    public let messageID: String
    public let model: String
    public let usage: AgentUsage
}

public struct AgentThinking: Sendable, Hashable {
    public let thinking: String
    public let signature: String
    public let messageID: String
}

public struct AgentToolUse: Sendable, Hashable {
    public let id: String
    public let name: String
    public let input: JSONValue
    public let messageID: String

    /// The one input field worth putting in a collapsed row header for file tools.
    public var filePath: String? { input["file_path"]?.stringValue }
}

public struct AgentToolResult: Sendable, Hashable {
    public let toolUseID: String
    public let text: String
    public let isError: Bool
    /// Screenshots arrive as image blocks. The bytes are not kept, only the fact they were there,
    /// so a row can offer to show them from the raw payload.
    public let hasImages: Bool
}

/// A slice of the raw Anthropic streaming API, present only with `--include-partial-messages`.
/// Good for live typing, worthless for a transcript: the `assistant` event that follows carries
/// the finished block.
public struct AgentStreamDelta: Sendable, Hashable {
    public enum Phase: String, Sendable {
        case messageStart = "message_start"
        case contentBlockStart = "content_block_start"
        case contentBlockDelta = "content_block_delta"
        case contentBlockStop = "content_block_stop"
        case messageDelta = "message_delta"
        case messageStop = "message_stop"
        case other
    }

    public enum Fragment: Sendable, Hashable {
        case text(String)
        case thinking(String)
        case signature(String)
        /// Partial JSON for a tool input. Accumulate it, it only parses once complete.
        case inputJSON(String)
    }

    public let phase: Phase
    public let rawPhase: String
    public let index: Int?
    public let blockType: String?
    public let fragment: Fragment?
}

public struct AgentStatus: Sendable, Hashable {
    public let status: String
}

public struct AgentThinkingTokens: Sendable, Hashable {
    public let estimatedTokens: Int
    public let estimatedTokensDelta: Int
}

/// Hook output can run to hundreds of kilobytes, so only the shape is decoded here. The body
/// stays in the raw payload and is never rendered wholesale.
public struct AgentHook: Sendable, Hashable {
    public enum Phase: String, Sendable {
        case started
        case response
    }

    public let phase: Phase
    public let name: String
    public let event: String?
    public let exitCode: Int?
    public let outcome: String?
}

/// The last line of a turn, and the only place a real cost and context window show up.
public struct AgentResult: Sendable, Hashable {
    public let subtype: String
    public let isError: Bool
    public let text: String
    public let durationMS: Int
    public let durationAPIMS: Int
    public let numTurns: Int
    public let stopReason: String?
    public let terminalReason: String?
    public let permissionDenials: Int
    public let usage: AgentUsage

    public var succeeded: Bool { !isError && subtype == "success" }
}

/// Token accounting, filled from either the thin `assistant` usage object or the richer one on
/// `result`. Cost and context window only ever arrive on `result`.
public struct AgentUsage: Sendable, Hashable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheCreationTokens: Int
    public var thinkingTokens: Int
    public var costUSD: Double
    public var contextWindow: Int

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        thinkingTokens: Int = 0,
        costUSD: Double = 0,
        contextWindow: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.thinkingTokens = thinkingTokens
        self.costUSD = costUSD
        self.contextWindow = contextWindow
    }

    public static let zero = AgentUsage()

    /// What the model actually had in front of it, which is what a "how full is the context"
    /// gauge needs. Cached tokens count: they occupy the window just the same.
    public var contextTokens: Int {
        inputTokens + cacheReadTokens + cacheCreationTokens
    }

    public var contextFraction: Double {
        contextWindow > 0 ? min(1, Double(contextTokens) / Double(contextWindow)) : 0
    }

    /// Read the shape shared by `assistant.message.usage` and `result.usage`.
    public static func decode(_ json: JSONValue?) -> AgentUsage {
        guard let json else { return .zero }
        return AgentUsage(
            inputTokens: json["input_tokens"]?.intValue ?? 0,
            outputTokens: json["output_tokens"]?.intValue ?? 0,
            cacheReadTokens: json["cache_read_input_tokens"]?.intValue ?? 0,
            cacheCreationTokens: json["cache_creation_input_tokens"]?.intValue ?? 0,
            thinkingTokens: json["output_tokens_details"]?["thinking_tokens"]?.intValue ?? 0
        )
    }
}

// MARK: - AgentEvent

/// One decoded line of the `claude` stream.
///
/// Every case pairs the envelope (raw bytes, uuid, session id, subagent parent) with a small
/// decoded payload. Nothing here throws and nothing here traps: a `type` or `subtype` shipped by
/// a future CLI release lands in `.unknown` with its bytes intact, and the session carries on.
public enum AgentEvent: Sendable {
    case initialized(AgentEnvelope, AgentInit)
    case assistantText(AgentEnvelope, AgentText)
    case thinking(AgentEnvelope, AgentThinking)
    case toolUse(AgentEnvelope, AgentToolUse)
    case toolResult(AgentEnvelope, AgentToolResult)
    case streamDelta(AgentEnvelope, AgentStreamDelta)
    case status(AgentEnvelope, AgentStatus)
    case thinkingTokens(AgentEnvelope, AgentThinkingTokens)
    case hook(AgentEnvelope, AgentHook)
    case result(AgentEnvelope, AgentResult)
    case rateLimit(AgentEnvelope)
    case unknown(AgentEnvelope)

    public var envelope: AgentEnvelope {
        switch self {
        case .initialized(let envelope, _): envelope
        case .assistantText(let envelope, _): envelope
        case .thinking(let envelope, _): envelope
        case .toolUse(let envelope, _): envelope
        case .toolResult(let envelope, _): envelope
        case .streamDelta(let envelope, _): envelope
        case .status(let envelope, _): envelope
        case .thinkingTokens(let envelope, _): envelope
        case .hook(let envelope, _): envelope
        case .result(let envelope, _): envelope
        case .rateLimit(let envelope): envelope
        case .unknown(let envelope): envelope
        }
    }

    public var raw: Data { envelope.raw }
    public var uuid: String? { envelope.uuid }
    public var sessionID: String? { envelope.sessionID }
    public var parentToolUseID: String? { envelope.parentToolUseID }

    /// The storage bucket this row belongs in. Detail beyond the bucket lives in the payload.
    public var kind: MessageKind {
        switch self {
        case .assistantText: .assistantText
        case .thinking: .thinking
        case .toolUse: .toolUse
        case .toolResult: .toolResult
        case .result: .result
        case .rateLimit: .notice
        case .initialized, .streamDelta, .status, .thinkingTokens, .hook, .unknown: .system
        }
    }

    /// Whether the event belongs in the stored transcript. Stream deltas do not: they are the
    /// same text arriving character by character, and the `assistant` event right behind them
    /// carries the finished block.
    public var isTranscriptRow: Bool {
        if case .streamDelta = self { return false }
        return true
    }

    /// The tool_use id a row should be filed under, so a tool result can find its call later.
    public var refID: String? {
        switch self {
        case .toolUse(_, let use): use.id
        case .toolResult(_, let result): result.toolUseID
        default: nil
        }
    }

    // MARK: Decoding

    /// Turn one NDJSON line into an event.
    ///
    /// Returns nil only for a blank line or bytes that are not JSON at all (the CLI can be killed
    /// mid-write). Anything that parses comes back as an event, `.unknown` at worst.
    public static func decode(line: String) -> AgentEvent? {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let raw = Data(line.utf8)
        guard let json = JSONValue.parse(raw) else { return nil }
        guard case .object = json else {
            return .unknown(AgentEnvelope(raw: raw, type: ""))
        }

        let type = json["type"]?.stringValue ?? ""
        let subtype = json["subtype"]?.stringValue
        let envelope = AgentEnvelope(
            raw: raw,
            type: type,
            subtype: subtype,
            uuid: json["uuid"]?.stringValue,
            sessionID: json["session_id"]?.stringValue,
            parentToolUseID: json["parent_tool_use_id"]?.stringValue
        )

        switch type {
        case "system": return decodeSystem(envelope, json)
        case "assistant": return decodeAssistant(envelope, json)
        case "user": return decodeUser(envelope, json)
        case "stream_event": return decodeStreamEvent(envelope, json)
        case "result": return decodeResult(envelope, json)
        case "rate_limit_event": return .rateLimit(envelope)
        default: return .unknown(envelope)
        }
    }

    private static func decodeSystem(_ envelope: AgentEnvelope, _ json: JSONValue) -> AgentEvent {
        switch envelope.subtype {
        case "init":
            return .initialized(envelope, AgentInit(
                sessionID: json["session_id"]?.stringValue ?? "",
                cwd: json["cwd"]?.stringValue ?? "",
                model: json["model"]?.stringValue ?? "",
                permissionMode: json["permissionMode"]?.stringValue ?? "",
                outputStyle: json["output_style"]?.stringValue ?? "",
                version: json["claude_code_version"]?.stringValue ?? "",
                tools: (json["tools"] ?? .null).stringArray,
                slashCommands: (json["slash_commands"] ?? .null).stringArray,
                agents: (json["agents"] ?? .null).stringArray
            ))

        case "status":
            return .status(envelope, AgentStatus(status: json["status"]?.stringValue ?? ""))

        case "thinking_tokens":
            return .thinkingTokens(envelope, AgentThinkingTokens(
                estimatedTokens: json["estimated_tokens"]?.intValue ?? 0,
                estimatedTokensDelta: json["estimated_tokens_delta"]?.intValue ?? 0
            ))

        case "hook_started", "hook_response":
            let phase: AgentHook.Phase = envelope.subtype == "hook_started" ? .started : .response
            return .hook(envelope, AgentHook(
                phase: phase,
                name: json["hook_name"]?.stringValue ?? "",
                event: json["hook_event"]?.stringValue,
                exitCode: json["exit_code"]?.intValue,
                outcome: json["outcome"]?.stringValue
            ))

        default:
            return .unknown(envelope)
        }
    }

    private static func decodeAssistant(_ envelope: AgentEnvelope, _ json: JSONValue) -> AgentEvent {
        guard let message = json["message"], let block = message["content"]?[0] else {
            return .unknown(envelope)
        }
        let messageID = message["id"]?.stringValue ?? ""

        switch block["type"]?.stringValue {
        case "text":
            return .assistantText(envelope, AgentText(
                text: block["text"]?.stringValue ?? "",
                messageID: messageID,
                model: message["model"]?.stringValue ?? "",
                usage: AgentUsage.decode(message["usage"])
            ))

        case "thinking":
            return .thinking(envelope, AgentThinking(
                thinking: block["thinking"]?.stringValue ?? "",
                signature: block["signature"]?.stringValue ?? "",
                messageID: messageID
            ))

        case "tool_use":
            return .toolUse(envelope, AgentToolUse(
                id: block["id"]?.stringValue ?? "",
                name: block["name"]?.stringValue ?? "",
                input: block["input"] ?? .object([:]),
                messageID: messageID
            ))

        default:
            return .unknown(envelope)
        }
    }

    private static func decodeUser(_ envelope: AgentEnvelope, _ json: JSONValue) -> AgentEvent {
        guard let block = json["message"]?["content"]?[0],
              block["type"]?.stringValue == "tool_result"
        else {
            return .unknown(envelope)
        }

        let rendered = renderToolResultContent(block["content"])
        return .toolResult(envelope, AgentToolResult(
            toolUseID: block["tool_use_id"]?.stringValue ?? "",
            text: rendered.text,
            isError: block["is_error"]?.boolValue ?? false,
            hasImages: rendered.hasImages
        ))
    }

    /// Tool result content is either a bare string or an array of blocks, and the array can hold
    /// screenshots. Both shapes reduce to text plus a flag.
    static func renderToolResultContent(_ content: JSONValue?) -> (text: String, hasImages: Bool) {
        guard let content else { return ("", false) }

        if let string = content.stringValue { return (string, false) }

        guard let blocks = content.arrayValue else { return (content.prettyPrinted, false) }

        var parts: [String] = []
        var hasImages = false
        for block in blocks {
            switch block["type"]?.stringValue {
            case "text": parts.append(block["text"]?.stringValue ?? "")
            case "image": hasImages = true
            default: break
            }
        }
        return (parts.joined(separator: "\n"), hasImages)
    }

    private static func decodeStreamEvent(_ envelope: AgentEnvelope, _ json: JSONValue) -> AgentEvent {
        guard let event = json["event"] else { return .unknown(envelope) }

        let rawPhase = event["type"]?.stringValue ?? ""
        var fragment: AgentStreamDelta.Fragment?
        if let delta = event["delta"] {
            switch delta["type"]?.stringValue {
            case "text_delta": fragment = .text(delta["text"]?.stringValue ?? "")
            case "thinking_delta": fragment = .thinking(delta["thinking"]?.stringValue ?? "")
            case "signature_delta": fragment = .signature(delta["signature"]?.stringValue ?? "")
            case "input_json_delta": fragment = .inputJSON(delta["partial_json"]?.stringValue ?? "")
            default: fragment = nil
            }
        }

        return .streamDelta(envelope, AgentStreamDelta(
            phase: AgentStreamDelta.Phase(rawValue: rawPhase) ?? .other,
            rawPhase: rawPhase,
            index: event["index"]?.intValue,
            blockType: event["content_block"]?["type"]?.stringValue,
            fragment: fragment
        ))
    }

    private static func decodeResult(_ envelope: AgentEnvelope, _ json: JSONValue) -> AgentEvent {
        var usage = AgentUsage.decode(json["usage"])
        usage.costUSD = json["total_cost_usd"]?.doubleValue ?? 0
        usage.contextWindow = (json["modelUsage"]?.objectValue ?? [:])
            .values
            .compactMap { $0["contextWindow"]?.intValue }
            .max() ?? 0

        return .result(envelope, AgentResult(
            subtype: envelope.subtype ?? "",
            isError: json["is_error"]?.boolValue ?? false,
            text: json["result"]?.stringValue ?? "",
            durationMS: json["duration_ms"]?.intValue ?? 0,
            durationAPIMS: json["duration_api_ms"]?.intValue ?? 0,
            numTurns: json["num_turns"]?.intValue ?? 0,
            stopReason: json["stop_reason"]?.stringValue,
            terminalReason: json["terminal_reason"]?.stringValue,
            permissionDenials: json["permission_denials"]?.arrayValue?.count ?? 0,
            usage: usage
        ))
    }
}
