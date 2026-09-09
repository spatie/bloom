import Foundation

/// One ACP event Bloom cares about, decoded from `grok agent stdio`.
///
/// Most of what the agent sends is noise for a transcript: MCP handshake progress, announcement
/// banners, settings dumps. Those land in `.unknown` with the method name intact and stop there.
/// `AgentEvent.unknown` is a stored row, so forwarding them would fill the chat with lines
/// nobody can read.
public enum GrokEvent: Sendable, Hashable {
    case sessionReady(GrokSession)
    case update(GrokSessionUpdate)
    case permission(GrokPermissionRequest)
    case promptCompleted(GrokPromptResult)
    case closed(reason: String)
    case unknown(method: String, raw: Data)

    public var sessionID: String? {
        switch self {
        case .sessionReady(let session): session.id
        case .update(let update): update.sessionID
        case .permission(let request): request.sessionID
        case .promptCompleted(let result): result.sessionID
        case .closed, .unknown: nil
        }
    }
}

public struct GrokSession: Sendable, Hashable {
    public let id: String
    public let models: [GrokModel]
    public let currentModelID: String
    public let raw: Data

    public init(id: String, models: [GrokModel] = [], currentModelID: String = "", raw: Data = Data()) {
        self.id = id
        self.models = models
        self.currentModelID = currentModelID
        self.raw = raw
    }

    public static func decode(_ json: JSONValue, raw: Data = Data()) -> GrokSession? {
        guard let id = json["sessionId"]?.stringValue, !id.isEmpty else { return nil }
        let modelsJSON = json["models"] ?? json["_meta"]?["modelState"] ?? .null
        return GrokSession(
            id: id,
            models: GrokModel.decodeList(modelsJSON),
            currentModelID: modelsJSON["currentModelId"]?.stringValue ?? "",
            raw: raw
        )
    }
}

public struct GrokSessionUpdate: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case text(String)
        case thought(String)
        case toolCall(GrokToolCall)
        case toolCallUpdate(GrokToolCall)
        case usage(used: Int, size: Int)
        case other(String)
    }

    public let sessionID: String
    public let kind: Kind
    public let raw: JSONValue

    public static func decode(params: JSONValue) -> GrokSessionUpdate? {
        let update = params["update"] ?? params
        guard let type = update["sessionUpdate"]?.stringValue else { return nil }
        let sessionID = params["sessionId"]?.stringValue ?? ""
        let kind: Kind
        switch type {
        case "agent_message_chunk":
            kind = .text(Self.contentText(update["content"]))
        case "agent_thought_chunk":
            kind = .thought(Self.contentText(update["content"]))
        case "tool_call":
            kind = .toolCall(GrokToolCall.decode(update, isUpdate: false))
        case "tool_call_update":
            kind = .toolCallUpdate(GrokToolCall.decode(update, isUpdate: true))
        case "usage_update":
            kind = .usage(
                used: update["used"]?.intValue ?? 0,
                size: update["size"]?.intValue ?? 0
            )
        default:
            kind = .other(type)
        }
        return GrokSessionUpdate(sessionID: sessionID, kind: kind, raw: update)
    }

    /// ACP content is `{ "type": "text", "text": "..." }` on chunks. A bare string is accepted
    /// because a future framing might flatten it and a missing sentence is worse than a loose one.
    static func contentText(_ json: JSONValue?) -> String {
        json?["text"]?.stringValue ?? json?.stringValue ?? ""
    }
}

public struct GrokToolCall: Sendable, Hashable {
    public let id: String
    public let title: String
    public let kind: String
    public let status: String
    public let toolName: String
    public let rawInput: JSONValue
    public let rawOutput: JSONValue
    public let contentText: String
    public let path: String
    public let json: JSONValue

    public static func decode(_ json: JSONValue, isUpdate: Bool) -> GrokToolCall {
        let locations = json["locations"]?.arrayValue ?? []
        let path = json["rawInput"]?["path"]?.stringValue
            ?? json["rawInput"]?["file_path"]?.stringValue
            ?? locations.first?["path"]?.stringValue
            ?? ""
        return GrokToolCall(
            id: json["toolCallId"]?.stringValue ?? "",
            title: json["title"]?.stringValue ?? "",
            kind: json["kind"]?.stringValue ?? "",
            status: json["status"]?.stringValue ?? (isUpdate ? "" : "pending"),
            toolName: json["toolName"]?.stringValue ?? "",
            rawInput: json["rawInput"] ?? .object([:]),
            rawOutput: json["rawOutput"] ?? .null,
            contentText: contentText(json["content"]),
            path: path,
            json: json
        )
    }

    /// Tool content is an array of `{ type, content }` / `{ type, path }` blocks. Flattened to
    /// one string so a result row has something to show without Bloom having to understand every
    /// ACP content kind.
    static func contentText(_ json: JSONValue?) -> String {
        guard let items = json?.arrayValue else {
            return json?["text"]?.stringValue ?? json?.stringValue ?? ""
        }
        return items.compactMap { item in
            if let text = item["content"]?["text"]?.stringValue { return text }
            if let text = item["text"]?.stringValue { return text }
            if item["type"]?.stringValue == "diff", let path = item["path"]?.stringValue {
                return path
            }
            return nil
        }.joined(separator: "\n")
    }

    public var isFinished: Bool {
        status == "completed" || status == "failed" || status == "cancelled"
    }

    public var isError: Bool {
        status == "failed" || status == "cancelled"
    }
}

public struct GrokPromptResult: Sendable, Hashable {
    public let requestID: GrokRequestID
    public let sessionID: String
    public let stopReason: String
    public let raw: JSONValue

    public init(
        requestID: GrokRequestID,
        sessionID: String,
        stopReason: String,
        raw: JSONValue
    ) {
        self.requestID = requestID
        self.sessionID = sessionID
        self.stopReason = stopReason
        self.raw = raw
    }

    public var wasCancelled: Bool { stopReason == "cancelled" }
    public var isError: Bool {
        stopReason == "refusal" || stopReason == "max_tokens" || stopReason == "max_turn_requests"
    }
}

public struct GrokPermissionOption: Sendable, Hashable {
    public let id: String
    public let name: String
    public let kind: String

    public static func decode(_ json: JSONValue) -> GrokPermissionOption? {
        guard let id = json["optionId"]?.stringValue, !id.isEmpty else { return nil }
        return GrokPermissionOption(
            id: id,
            name: json["name"]?.stringValue ?? id,
            kind: json["kind"]?.stringValue ?? ""
        )
    }

    public var isAllow: Bool { kind.hasPrefix("allow") }
    public var isAlways: Bool { kind == "allow_always" || kind == "reject_always" }
}

public struct GrokPermissionRequest: Sendable, Hashable {
    public let id: GrokRequestID
    public let sessionID: String
    public let toolCall: GrokToolCall
    public let options: [GrokPermissionOption]
    public let raw: Data

    public static func decode(_ request: GrokServerRequest) -> GrokPermissionRequest? {
        guard request.method == "session/request_permission" else { return nil }
        let toolJSON = request.params["toolCall"] ?? .object([:])
        let options = (request.params["options"]?.arrayValue ?? []).compactMap(GrokPermissionOption.decode)
        return GrokPermissionRequest(
            id: request.id,
            sessionID: request.params["sessionId"]?.stringValue ?? "",
            toolCall: GrokToolCall.decode(toolJSON, isUpdate: false),
            options: options,
            raw: request.raw
        )
    }
}
