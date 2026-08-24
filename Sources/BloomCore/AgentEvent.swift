import Foundation

// MARK: - JSONValue

/// A closed representation of any JSON document.
///
/// Tool input is arbitrary JSON that Bloom neither controls nor fully understands, so it has to
/// survive a round trip untouched. Modelling it as an enum rather than `Any` keeps it `Sendable`,
/// keeps it out of the dynamic-cast business, and lets a renderer written a year from now dig
/// into a payload nobody thought to decode today.
public enum JSONValue: Sendable, Hashable, Codable {
    case string(String)
    /// A whole number that fits in `Int`. Kept apart from `.number` because `Double` silently
    /// rewrites anything past 2^53: `9007199254740993` comes back as `...992`, which is not the
    /// raw JSON the store promises to hand back.
    case integer(Int)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    /// How deep a document may nest before it is refused.
    ///
    /// Decoding recurses once per level, and a Swift concurrency thread has a small stack: a line
    /// nested two hundred deep took the whole process down with a stack overflow, which no line
    /// off a subprocess gets to do. Real payloads sit around ten levels deep, tool input included,
    /// so this is far out of the way of anything the CLI actually emits.
    public static let maximumNesting = 64

    public init(from decoder: Decoder) throws {
        let counter = decoder.userInfo[Self.depthKey] as? DepthCounter
        let depth = counter?.depth ?? decoder.codingPath.count
        guard depth < Self.maximumNesting else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "JSON nested deeper than \(Self.maximumNesting) levels"
            ))
        }
        counter?.depth = depth + 1
        defer { counter?.depth = depth }

        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        // Integer first: a `Double` round trip is lossy above 2^53, and token counts, durations
        // and exit codes are all integers to begin with.
        if let value = try? container.decode(Int.self) { self = .integer(value); return }
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
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Counts nesting for one decode. `Decoder.codingPath` answers the same question, but it
    /// rebuilds an array on every value, which is not something to do once per byte of a hook
    /// payload. It is still the fallback for a decoder Bloom did not build itself.
    /// Unchecked because a decode is single threaded: the counter is created in `parse`, used by
    /// that one decoder, and dropped when it returns. It never crosses a thread.
    private final class DepthCounter: @unchecked Sendable {
        var depth = 0
    }

    private static let depthKey = CodingUserInfoKey(rawValue: "be.spatie.bloom.jsonDepth")!

    /// Parse one JSON document. Returns nil instead of throwing, because every caller in Bloom is
    /// on a path that must never abort the stream. Documents nested past `maximumNesting` are
    /// refused the same way malformed bytes are.
    public static func parse(_ data: Data) -> JSONValue? {
        let decoder = JSONDecoder()
        decoder.userInfo[depthKey] = DepthCounter()
        return try? decoder.decode(JSONValue.self, from: data)
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
        switch self {
        case .integer(let value): Double(value)
        case .number(let value): value
        default: nil
        }
    }

    /// Nil rather than a trap for anything `Int` cannot hold. A single valid `thinking_tokens`
    /// line carrying `1e100` used to kill the process here, and no line off a subprocess is ever
    /// allowed to do that.
    public var intValue: Int? {
        switch self {
        case .integer(let value): value
        case .number(let value): Int(exactly: value.rounded(.towardZero))
        default: nil
        }
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

    /// A JSON `null` reads as a missing key, because for every field Bloom cares about the two
    /// mean the same thing (`is_error` and `parent_tool_use_id` are explicitly null constantly).
    public subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self, let value = object[key], !value.isNull else { return nil }
        return value
    }

    public subscript(index: Int) -> JSONValue? {
        guard case .array(let array) = self, array.indices.contains(index) else { return nil }
        return array[index]
    }

    /// Strings out of an array, skipping anything that is not one. Used for the tool and slash
    /// command lists on the init event.
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

// MARK: - Payloads

/// Everything the first line of a session binds: the id to resume with, the model that answered,
/// and what it was allowed to do.
public struct AgentInit: Sendable, Hashable {
    public let sessionID: String
    public let cwd: String
    public let model: String
    public let permissionMode: String
    public let tools: [String]
    public let slashCommands: [String]
    public let agents: [String]
    public let outputStyle: String
    public let version: String
    public let raw: Data
    public let uuid: String?

    public init(
        sessionID: String,
        cwd: String = "",
        model: String = "",
        permissionMode: String = "",
        tools: [String] = [],
        slashCommands: [String] = [],
        agents: [String] = [],
        outputStyle: String = "",
        version: String = "",
        raw: Data = Data(),
        uuid: String? = nil
    ) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.model = model
        self.permissionMode = permissionMode
        self.tools = tools
        self.slashCommands = slashCommands
        self.agents = agents
        self.outputStyle = outputStyle
        self.version = version
        self.raw = raw
        self.uuid = uuid
    }
}

/// A finished text or thinking block. Both shapes are one string plus the envelope, so they share
/// a type rather than duplicating it.
public struct AgentTextBlock: Sendable, Hashable {
    public let text: String
    public let parentToolUseID: String?
    public let raw: Data
    /// Only present on thinking blocks, and only ever needed to replay a block back to the API.
    public let signature: String
    public let messageID: String
    public let model: String
    public let usage: AgentUsage
    public let uuid: String?
    public let sessionID: String?

    public init(
        text: String,
        parentToolUseID: String? = nil,
        raw: Data = Data(),
        signature: String = "",
        messageID: String = "",
        model: String = "",
        usage: AgentUsage = .zero,
        uuid: String? = nil,
        sessionID: String? = nil
    ) {
        self.text = text
        self.parentToolUseID = parentToolUseID
        self.raw = raw
        self.signature = signature
        self.messageID = messageID
        self.model = model
        self.usage = usage
        self.uuid = uuid
        self.sessionID = sessionID
    }
}

public struct AgentToolUse: Sendable, Hashable {
    public let id: String
    public let name: String
    public let input: JSONValue
    public let parentToolUseID: String?
    public let raw: Data
    public let messageID: String
    public let uuid: String?
    public let sessionID: String?

    public init(
        id: String,
        name: String,
        input: JSONValue,
        parentToolUseID: String? = nil,
        raw: Data = Data(),
        messageID: String = "",
        uuid: String? = nil,
        sessionID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.input = input
        self.parentToolUseID = parentToolUseID
        self.raw = raw
        self.messageID = messageID
        self.uuid = uuid
        self.sessionID = sessionID
    }

    /// The one input field worth putting in a collapsed row header for the file tools.
    public var filePath: String? { input["file_path"]?.stringValue }
}

public struct AgentToolResult: Sendable, Hashable {
    public let toolUseID: String
    public let text: String
    public let isError: Bool
    /// Set when the call never ran. `is_error` is true for a refusal as well as for a failure, so
    /// this is what separates the two. See `ToolRefusal`.
    public let refusal: ToolRefusal?
    /// Screenshots come back as image blocks. The bytes are not lifted out, only the fact that
    /// they were there, so a row can offer to pull them from the raw payload.
    public let hasImages: Bool
    public let raw: Data
    public let parentToolUseID: String?
    public let uuid: String?
    public let sessionID: String?

    public init(
        toolUseID: String,
        text: String,
        isError: Bool = false,
        refusal: ToolRefusal? = nil,
        hasImages: Bool = false,
        raw: Data = Data(),
        parentToolUseID: String? = nil,
        uuid: String? = nil,
        sessionID: String? = nil
    ) {
        self.toolUseID = toolUseID
        self.text = text
        self.isError = isError
        self.refusal = refusal
        self.hasImages = hasImages
        self.raw = raw
        self.parentToolUseID = parentToolUseID
        self.uuid = uuid
        self.sessionID = sessionID
    }
}

/// A slice of the raw Anthropic streaming API, present only with `--include-partial-messages`.
/// Good for live typing, worthless for a transcript: the `assistant` event right behind it
/// carries the finished block. Anything with no live-rendering use decodes as `.unknown`.
public enum StreamDelta: Sendable, Hashable {
    case text(String)
    case thinking(String)
    case toolName(String)
    /// A chunk of `partial_json`. Accumulate it, it only parses once the block is complete.
    case toolInput(String)
    case blockFinished
}

/// Hook output runs to hundreds of kilobytes, so only the shape is decoded. The body stays in the
/// raw payload and is never rendered wholesale.
public struct AgentHook: Sendable, Hashable {
    public let name: String
    public let event: String
    public let outcome: String?
    public let exitCode: Int?
    public let raw: Data
    public let started: Bool
    public let uuid: String?
    public let sessionID: String?

    public init(
        name: String,
        event: String = "",
        outcome: String? = nil,
        exitCode: Int? = nil,
        raw: Data = Data(),
        started: Bool = false,
        uuid: String? = nil,
        sessionID: String? = nil
    ) {
        self.name = name
        self.event = event
        self.outcome = outcome
        self.exitCode = exitCode
        self.raw = raw
        self.started = started
        self.uuid = uuid
        self.sessionID = sessionID
    }
}

/// The last line of a turn, and the only place a real cost and context window show up.
public struct AgentResult: Sendable, Hashable {
    public let usage: AgentUsage
    public let summary: String
    public let isError: Bool
    public let subtype: String
    public let durationMS: Int
    public let numTurns: Int
    public let stopReason: String?
    public let raw: Data
    public let durationAPIMS: Int
    public let terminalReason: String?
    public let permissionDenials: Int
    public let uuid: String?
    public let sessionID: String?

    public init(
        usage: AgentUsage = .zero,
        summary: String = "",
        isError: Bool = false,
        subtype: String = "success",
        durationMS: Int = 0,
        numTurns: Int = 0,
        stopReason: String? = nil,
        raw: Data = Data(),
        durationAPIMS: Int = 0,
        terminalReason: String? = nil,
        permissionDenials: Int = 0,
        uuid: String? = nil,
        sessionID: String? = nil
    ) {
        self.usage = usage
        self.summary = summary
        self.isError = isError
        self.subtype = subtype
        self.durationMS = durationMS
        self.numTurns = numTurns
        self.stopReason = stopReason
        self.raw = raw
        self.durationAPIMS = durationAPIMS
        self.terminalReason = terminalReason
        self.permissionDenials = permissionDenials
        self.uuid = uuid
        self.sessionID = sessionID
    }

    public var succeeded: Bool { !isError && subtype == "success" }
}

/// Not a CLI event type. The runner synthesises one when the process dies without ever saying
/// how it went, so the transcript never just stops mid sentence.
public struct AgentError: Sendable, Hashable {
    public let message: String
    public let raw: Data

    public init(message: String, raw: Data = Data()) {
        self.message = message
        self.raw = raw
    }
}

extension AgentError {
    /// The `.error` event a runner emits when the store refuses a write.
    ///
    /// Its payload never reaches the database, for the obvious reason, so it only ever exists in
    /// flight; and it goes straight to the sink rather than through the runner's ingest path,
    /// because storing a row is exactly what just failed. Both runners emit it, so a failing
    /// database looks the same in a Codex chat as in a Claude Code one.
    static func storage(message: String) -> AgentError {
        struct StorageFailure: Encodable {
            let type = "error"
            let subtype = "storage"
            let message: String
        }
        let payload = (try? JSONEncoder().encode(StorageFailure(message: message)))
            ?? Data(#"{"type":"error","subtype":"storage"}"#.utf8)
        return AgentError(message: message, raw: payload)
    }
}

/// Token accounting, filled from either the thin `assistant` usage object or the richer one on
/// `result`. Cost and the context window only ever arrive on `result`.
public struct AgentUsage: Sendable, Hashable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheCreationTokens: Int
    public var thinkingTokens: Int
    public var costUSD: Double
    /// The size of the context window, from `modelUsage.<model>.contextWindow`. Zero when the
    /// event did not carry one, which is every event except `result`.
    public var contextTokens: Int

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        thinkingTokens: Int = 0,
        costUSD: Double = 0,
        contextTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.thinkingTokens = thinkingTokens
        self.costUSD = costUSD
        self.contextTokens = contextTokens
    }

    public static let zero = AgentUsage()

    /// What the model actually had in front of it. Cached tokens count, they occupy the window
    /// just the same, which is what a "how full is the context" gauge has to measure.
    public var contextUsedTokens: Int {
        inputTokens + cacheReadTokens + cacheCreationTokens
    }

    public var contextFraction: Double {
        contextTokens > 0 ? min(1, Double(contextUsedTokens) / Double(contextTokens)) : 0
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
/// Nothing here throws and nothing here traps. A `type` or `subtype` shipped by a future CLI
/// release lands in `.unknown` with its bytes intact and the session carries on, which is the
/// whole reason the raw line travels with every case.
public enum AgentEvent: Sendable {
    case initialized(AgentInit)
    case assistantText(AgentTextBlock)
    case thinking(AgentTextBlock)
    case toolUse(AgentToolUse)
    case toolResult(AgentToolResult)
    case streamDelta(StreamDelta)
    case status(String)
    case thinkingTokens(Int)
    case hook(AgentHook)
    /// The agent asking to run something, with its turn held open until Bloom answers. Only ever
    /// emitted when the CLI was launched with `--permission-prompt-tool stdio`.
    case permissionAsk(PermissionAsk)
    /// One question has been answered, by a person or by a rule they granted earlier. A live
    /// signal only: the durable record is the `permission_asks` table, which is what a transcript
    /// reopened tomorrow reads.
    case permissionDecided(PermissionResolution)
    case result(AgentResult)
    /// The turn, or a subagent inside it, waiting out somebody else's outage. A live signal
    /// rather than a row: see `AgentRetry`.
    case retrying(AgentRetry)
    case rateLimit(Data)
    case error(AgentError)
    case unknown(Data)

    /// The original bytes of the line. A stream delta has none worth keeping: it is never stored
    /// and its content is superseded a moment later.
    public var raw: Data {
        switch self {
        case .initialized(let value): value.raw
        case .assistantText(let value), .thinking(let value): value.raw
        case .toolUse(let value): value.raw
        case .toolResult(let value): value.raw
        case .hook(let value): value.raw
        case .permissionAsk(let value): value.raw
        case .permissionDecided: Data()
        case .result(let value): value.raw
        case .retrying(let value): value.raw
        case .error(let value): value.raw
        case .rateLimit(let raw), .unknown(let raw): raw
        case .streamDelta, .status, .thinkingTokens: Data()
        }
    }

    /// Non-nil when the event came from inside a subagent (the Agent tool), so those rows can be
    /// indented rather than mixed into the main flow.
    public var parentToolUseID: String? {
        switch self {
        case .assistantText(let value), .thinking(let value): value.parentToolUseID
        case .toolUse(let value): value.parentToolUseID
        case .toolResult(let value): value.parentToolUseID
        default: nil
        }
    }

    public var sessionID: String? {
        switch self {
        case .initialized(let value): value.sessionID
        case .assistantText(let value), .thinking(let value): value.sessionID
        case .toolUse(let value): value.sessionID
        case .toolResult(let value): value.sessionID
        case .hook(let value): value.sessionID
        case .result(let value): value.sessionID
        case .retrying(let value): value.sessionID
        default: nil
        }
    }

    public var uuid: String? {
        switch self {
        case .initialized(let value): value.uuid
        case .assistantText(let value), .thinking(let value): value.uuid
        case .toolUse(let value): value.uuid
        case .toolResult(let value): value.uuid
        case .hook(let value): value.uuid
        case .result(let value): value.uuid
        case .retrying(let value): value.uuid
        default: nil
        }
    }

    /// The storage bucket this row belongs in. Everything finer lives in the stored payload.
    public var kind: MessageKind {
        switch self {
        case .assistantText: .assistantText
        case .thinking: .thinking
        case .toolUse: .toolUse
        case .toolResult: .toolResult
        case .permissionAsk: .permissionAsk
        case .result: .result
        case .error: .error
        case .rateLimit: .notice
        case .initialized, .streamDelta, .status, .thinkingTokens, .hook, .permissionDecided,
             .retrying, .unknown:
            .system
        }
    }

    /// Whether the event belongs in the stored transcript. Stream deltas do not: they are the
    /// same text arriving character by character, and the `assistant` event behind them carries
    /// the finished block. Status and thinking-token ticks are live indicators, not history.
    public var isTranscriptRow: Bool {
        switch self {
        // A decision is not a row. The question is the row, and what was decided about it is
        // read back off the ask itself, so answering one must not append anything.
        // A retry is not a row either. Ten attempts against one request are one fact, nine
        // tenths of it stale, and the durable record of a run that recovered is the sentence
        // `RetryRun` leaves under the turn rather than ten stored lines.
        case .streamDelta, .status, .thinkingTokens, .permissionDecided, .retrying: false
        default: true
        }
    }

    /// The tool_use id a row is filed under, so a tool result can find its call later.
    public var refID: String? {
        switch self {
        case .toolUse(let value): value.id
        case .toolResult(let value): value.toolUseID
        // Filed under the call it is about, so the row lands where the call would have been.
        case .permissionAsk(let value): value.toolUseID
        case .permissionDecided(let value): value.toolUseID
        // The Agent call the retrying subagent belongs to, so a row drawn for that call can pick
        // its own retries out of the stream.
        case .retrying(let value):
            if case .subagent(_, let toolUseID, _) = value.scope { toolUseID } else { nil }
        default: nil
        }
    }

    // MARK: Decoding

    /// Turn one NDJSON line into an event.
    ///
    /// Returns nil only for a blank line or for bytes that are not JSON at all, which happens
    /// when the CLI is killed mid-write. Anything that parses comes back as an event, `.unknown`
    /// at worst.
    public static func decode(line: String) -> AgentEvent? {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let raw = Data(line.utf8)
        guard let json = JSONValue.parse(raw) else { return nil }
        guard case .object = json else { return .unknown(raw) }

        switch json["type"]?.stringValue {
        case "system": return decodeSystem(json, raw: raw)
        case "assistant": return decodeAssistant(json, raw: raw)
        case "user": return decodeUser(json, raw: raw)
        case "stream_event": return decodeStreamEvent(json, raw: raw)
        case "result": return decodeResult(json, raw: raw)
        case "rate_limit_event": return .rateLimit(raw)
        // Only the retry block is lifted out here. The rest of `tool_progress` is an elapsed
        // seconds tick for a call already on screen, and a line this decoder has no reading of
        // belongs in `.unknown` with its bytes intact rather than half understood.
        case "tool_progress":
            guard let retry = AgentRetry.subagentRetry(json, raw: raw) else { return .unknown(raw) }
            return .retrying(retry)
        // The sixth type. It used to fall to `.unknown` and be dropped on the floor, which is
        // exactly what "Bloom never asks" looked like from the inside: the CLI was willing to ask
        // and nobody was reading the line. Only `can_use_tool` is lifted out; the other control
        // subtypes are the CLI answering Bloom, or asking something Bloom has no business
        // answering, and they stay `.unknown` rather than being half understood.
        case "control_request":
            guard let ask = PermissionAsk.decode(json, raw: raw) else { return .unknown(raw) }
            return .permissionAsk(ask)
        default: return .unknown(raw)
        }
    }

    private static func decodeSystem(_ json: JSONValue, raw: Data) -> AgentEvent {
        switch json["subtype"]?.stringValue {
        case "init":
            return .initialized(AgentInit(
                sessionID: json["session_id"]?.stringValue ?? "",
                cwd: json["cwd"]?.stringValue ?? "",
                model: json["model"]?.stringValue ?? "",
                permissionMode: json["permissionMode"]?.stringValue ?? "",
                tools: (json["tools"] ?? .null).stringArray,
                slashCommands: (json["slash_commands"] ?? .null).stringArray,
                agents: (json["agents"] ?? .null).stringArray,
                outputStyle: json["output_style"]?.stringValue ?? "",
                version: json["claude_code_version"]?.stringValue ?? "",
                raw: raw,
                uuid: json["uuid"]?.stringValue
            ))

        case "status":
            return .status(json["status"]?.stringValue ?? "")

        case "thinking_tokens":
            return .thinkingTokens(json["estimated_tokens"]?.intValue ?? 0)

        case "api_retry":
            return .retrying(AgentRetry.turnRetry(json, raw: raw))

        case "hook_started", "hook_response":
            return .hook(AgentHook(
                name: json["hook_name"]?.stringValue ?? "",
                event: json["hook_event"]?.stringValue ?? "",
                outcome: json["outcome"]?.stringValue,
                exitCode: json["exit_code"]?.intValue,
                raw: raw,
                started: json["subtype"]?.stringValue == "hook_started",
                uuid: json["uuid"]?.stringValue,
                sessionID: json["session_id"]?.stringValue
            ))

        default:
            return .unknown(raw)
        }
    }

    private static func decodeAssistant(_ json: JSONValue, raw: Data) -> AgentEvent {
        guard let message = json["message"], let block = message["content"]?[0] else {
            return .unknown(raw)
        }

        let parentToolUseID = json["parent_tool_use_id"]?.stringValue
        let uuid = json["uuid"]?.stringValue
        let sessionID = json["session_id"]?.stringValue
        let messageID = message["id"]?.stringValue ?? ""
        let model = message["model"]?.stringValue ?? ""
        let usage = AgentUsage.decode(message["usage"])

        switch block["type"]?.stringValue {
        case "text":
            return .assistantText(AgentTextBlock(
                text: block["text"]?.stringValue ?? "",
                parentToolUseID: parentToolUseID,
                raw: raw,
                messageID: messageID,
                model: model,
                usage: usage,
                uuid: uuid,
                sessionID: sessionID
            ))

        case "thinking":
            return .thinking(AgentTextBlock(
                text: block["thinking"]?.stringValue ?? "",
                parentToolUseID: parentToolUseID,
                raw: raw,
                signature: block["signature"]?.stringValue ?? "",
                messageID: messageID,
                model: model,
                usage: usage,
                uuid: uuid,
                sessionID: sessionID
            ))

        case "tool_use":
            return .toolUse(AgentToolUse(
                id: block["id"]?.stringValue ?? "",
                name: block["name"]?.stringValue ?? "",
                input: block["input"] ?? .object([:]),
                parentToolUseID: parentToolUseID,
                raw: raw,
                messageID: messageID,
                uuid: uuid,
                sessionID: sessionID
            ))

        default:
            return .unknown(raw)
        }
    }

    private static func decodeUser(_ json: JSONValue, raw: Data) -> AgentEvent {
        guard let block = json["message"]?["content"]?[0],
              block["type"]?.stringValue == "tool_result"
        else {
            return .unknown(raw)
        }

        let rendered = renderToolResultContent(block["content"])
        let toolUseID = block["tool_use_id"]?.stringValue ?? ""
        let isError = block["is_error"]?.boolValue ?? false
        return .toolResult(AgentToolResult(
            toolUseID: toolUseID,
            text: rendered.text,
            isError: isError,
            refusal: isError ? refusal(in: json, for: toolUseID) : nil,
            hasImages: rendered.hasImages,
            raw: raw,
            parentToolUseID: json["parent_tool_use_id"]?.stringValue,
            uuid: json["uuid"]?.stringValue,
            sessionID: json["session_id"]?.stringValue
        ))
    }

    /// Whether the CLI says this call never ran, and why.
    ///
    /// `tool_result_meta` sits beside the message rather than inside the block, and one `user`
    /// event can close more than one call, so the entry is found by id. See `ToolRefusal`.
    private static func refusal(in json: JSONValue, for toolUseID: String) -> ToolRefusal? {
        let entry = json["tool_result_meta"]?.arrayValue?
            .first { $0["id"]?.stringValue == toolUseID }
        return ToolRefusal(protocolKind: entry?["non_execution_kind"]?.stringValue)
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

    private static func decodeStreamEvent(_ json: JSONValue, raw: Data) -> AgentEvent {
        guard let event = json["event"] else { return .unknown(raw) }

        switch event["type"]?.stringValue {
        case "content_block_start":
            guard let block = event["content_block"], block["type"]?.stringValue == "tool_use" else {
                return .unknown(raw)
            }
            return .streamDelta(.toolName(block["name"]?.stringValue ?? ""))

        case "content_block_delta":
            guard let delta = event["delta"] else { return .unknown(raw) }
            switch delta["type"]?.stringValue {
            case "text_delta": return .streamDelta(.text(delta["text"]?.stringValue ?? ""))
            case "thinking_delta": return .streamDelta(.thinking(delta["thinking"]?.stringValue ?? ""))
            case "input_json_delta": return .streamDelta(.toolInput(delta["partial_json"]?.stringValue ?? ""))
            default: return .unknown(raw)
            }

        case "content_block_stop":
            return .streamDelta(.blockFinished)

        default:
            return .unknown(raw)
        }
    }

    private static func decodeResult(_ json: JSONValue, raw: Data) -> AgentEvent {
        var usage = AgentUsage.decode(json["usage"])
        usage.costUSD = json["total_cost_usd"]?.doubleValue ?? 0
        usage.contextTokens = (json["modelUsage"]?.objectValue ?? [:])
            .values
            .compactMap { $0["contextWindow"]?.intValue }
            .max() ?? 0

        return .result(AgentResult(
            usage: usage,
            summary: json["result"]?.stringValue ?? "",
            isError: json["is_error"]?.boolValue ?? false,
            subtype: json["subtype"]?.stringValue ?? "",
            durationMS: json["duration_ms"]?.intValue ?? 0,
            numTurns: json["num_turns"]?.intValue ?? 0,
            stopReason: json["stop_reason"]?.stringValue,
            raw: raw,
            durationAPIMS: json["duration_api_ms"]?.intValue ?? 0,
            terminalReason: json["terminal_reason"]?.stringValue,
            permissionDenials: json["permission_denials"]?.arrayValue?.count ?? 0,
            uuid: json["uuid"]?.stringValue,
            sessionID: json["session_id"]?.stringValue
        ))
    }
}
