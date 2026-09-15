import Foundation

/// The wire vocabulary of `grok agent stdio`, which speaks ACP as JSON-RPC 2.0 over stdio.
///
/// ## Why this protocol and not `grok -p --output-format streaming-messages-json`
///
/// Headless `-p` is NDJSON in the Messages API shape Bloom already stores, and looks like a
/// drop-in for `AgentRunner`. It is a trap, measured against grok 1.0.24:
///
///   * **One prompt, then exit.** stdin is not a conversation. Follow-up turns are a new process
///     with `--resume`, which is not how Bloom holds a chat open.
///   * **Read only.** The headless docs say tool approvals and other bidirectional flows use ACP.
///     A permission question has nowhere to land, so the only honest headless mode is
///     `--always-approve`.
///
/// `grok agent --no-leader stdio` is the real interface: `initialize`, `session/new` /
/// `session/resume`, `session/prompt` (held open for the whole turn), `session/update`
/// notifications, and `session/request_permission` as a server-to-client request. `--no-leader`
/// is load-bearing: without it a Bloom chat can attach to the owner's interactive TUI leader.
///
/// Frame classification is the JSON-RPC one, never by id: `method` plus `id` is a request,
/// `method` alone a notification, `result` or `error` a response. Request ids on this wire are
/// numbers Bloom assigns, and the server's permission requests use the same numbering, so a
/// frame is never typed by looking at its id.
public enum GrokRequestID: Sendable, Hashable, Codable {
    case number(Int)
    case text(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .number(value)
        } else {
            self = .text(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .text(let value): try container.encode(value)
        }
    }

    var jsonLiteral: String {
        switch self {
        case .number(let value): String(value)
        case .text(let value): JSONValue.string(value).compactJSON
        }
    }

    /// The turn handle's id for this request. Distinct from the ACP session id, which is stable
    /// across turns and must not be reused as a turn id.
    var turnID: String {
        switch self {
        case .number(let value): String(value)
        case .text(let value): value
        }
    }

    init?(_ json: JSONValue?) {
        switch json {
        case .integer(let value): self = .number(value)
        case .string(let value): self = .text(value)
        default: return nil
        }
    }
}

public struct GrokRPCError: Sendable, Hashable, Error {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public enum GrokClientError: Sendable, Error, Equatable {
    case connectionClosed(String)
    case unexpectedResult(method: String)
    case notInitialized
    case timedOut(method: String, seconds: Int)
}

public struct GrokServerRequest: Sendable, Hashable {
    public let id: GrokRequestID
    public let method: String
    public let params: JSONValue
    public let raw: Data

    public init(id: GrokRequestID, method: String, params: JSONValue, raw: Data = Data()) {
        self.id = id
        self.method = method
        self.params = params
        self.raw = raw
    }
}

public struct GrokServerNotification: Sendable, Hashable {
    public let method: String
    public let params: JSONValue
    public let raw: Data

    public init(method: String, params: JSONValue, raw: Data = Data()) {
        self.method = method
        self.params = params
        self.raw = raw
    }
}

/// One decoded line off the agent.
///
/// Nothing here throws. A line that is not JSON comes back as `.malformed` with its bytes intact,
/// because the agent writes tracing to stderr and a future release could write something new to
/// stdout, and neither may end a session.
public enum GrokFrame: Sendable, Hashable {
    case response(id: GrokRequestID, result: JSONValue, raw: Data)
    case failure(id: GrokRequestID, error: GrokRPCError, raw: Data)
    case request(GrokServerRequest)
    case notification(GrokServerNotification)
    case malformed(Data)

    public static func decode(line: String) -> GrokFrame? {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let raw = Data(line.utf8)
        guard let json = JSONValue.parse(raw), case .object = json else { return .malformed(raw) }

        let id = GrokRequestID(json["id"])
        let params = json["params"] ?? .object([:])

        if let method = json["method"]?.stringValue {
            if let id {
                return .request(GrokServerRequest(id: id, method: method, params: params, raw: raw))
            }
            return .notification(GrokServerNotification(method: method, params: params, raw: raw))
        }

        guard let id else { return .malformed(raw) }

        if let error = json["error"] {
            return .failure(
                id: id,
                error: GrokRPCError(
                    code: error["code"]?.intValue ?? 0,
                    message: error["message"]?.stringValue ?? "",
                    data: error["data"]
                ),
                raw: raw
            )
        }

        guard case .object(let object) = json, object.keys.contains("result") else {
            return .malformed(raw)
        }
        return .response(id: id, result: object["result"] ?? .null, raw: raw)
    }
}

public enum GrokOutgoing {
    static let version = "2.0"

    public static func request(id: GrokRequestID, method: String, params: JSONValue?) -> String {
        var members = ["\"jsonrpc\":\"\(version)\"", "\"id\":\(id.jsonLiteral)"]
        members.append("\"method\":\(JSONValue.string(method).compactJSON)")
        if let params { members.append("\"params\":\(params.compactJSON)") }
        return "{" + members.joined(separator: ",") + "}"
    }

    public static func notification(method: String, params: JSONValue?) -> String {
        var members = ["\"jsonrpc\":\"\(version)\""]
        members.append("\"method\":\(JSONValue.string(method).compactJSON)")
        if let params { members.append("\"params\":\(params.compactJSON)") }
        return "{" + members.joined(separator: ",") + "}"
    }

    public static func response(id: GrokRequestID, result: JSONValue) -> String {
        "{\"jsonrpc\":\"\(version)\",\"id\":\(id.jsonLiteral),\"result\":\(result.compactJSON)}"
    }

    public static func failure(id: GrokRequestID, code: Int, message: String) -> String {
        let error = JSONValue.object([
            "code": .integer(code),
            "message": .string(message),
        ])
        return "{\"jsonrpc\":\"\(version)\",\"id\":\(id.jsonLiteral),\"error\":\(error.compactJSON)}"
    }
}
