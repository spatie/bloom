import Foundation

// MARK: - Why app-server

/// The wire vocabulary of `codex app-server`, which speaks JSON-RPC 2.0 over stdio.
///
/// ## Why this protocol and not `codex exec --json`
///
/// `codex exec --json` is NDJSON, one event per line, and looks like a drop-in for the shape
/// `AgentRunner` already consumes. It is a trap, and it was measured rather than guessed against
/// codex-cli 0.147.0:
///
///   * No text deltas. Events arrive at item granularity, so a reply appears all at once when it
///     is finished. Bloom's transcript types as the model does, and `exec` cannot do that.
///   * No reasoning items at all, so the thinking rows would simply be missing.
///   * **No approvals.** Run with `-s read-only -c approval_policy=on-request` and a prompt that
///     has to write a file, nothing is ever asked: the patch is refused and the turn carries on.
///     There is no wire on which a question could arrive, which is the same failure Bloom already
///     fixed once for Claude Code with `--permission-prompt-tool stdio`.
///
/// `codex app-server --listen stdio://` is the real interface: 95 client methods, 70 server
/// notifications and 10 server-to-client requests, including the five approval shapes. One short
/// turn produced fifteen `item/agentMessage/delta` notifications, typed `item/started` and
/// `item/completed` for every item, token usage, rate limits and `thread/status/changed`. It is
/// also what Conductor drives. So Bloom takes app-server, and `exec` is never used.
///
/// ## Where these types come from
///
/// The protocol describes itself: `codex app-server generate-json-schema --out <dir>` writes the
/// whole thing out, and every type here was checked against that dump rather than inferred from a
/// transcript. Two details from the dump that a hand-written client gets wrong:
///
///   * There is no `jsonrpc` member. `JSONRPCRequest`, `JSONRPCResponse`, `JSONRPCNotification`
///     and `JSONRPCError` each carry only the fields below, and the real server sends none. A
///     decoder that requires `"jsonrpc": "2.0"` drops every line. Bloom still sends it, because a
///     server that ignores an extra member costs nothing and a strict one would need it.
///   * Server-to-client request ids live in the server's own numbering and start at 0, which is
///     also a perfectly good id for one of ours. So a frame is classified by which members it
///     has, never by its id: `method` plus `id` is a request, `method` alone a notification,
///     `result` or `error` a response.
public enum CodexRequestID: Sendable, Hashable, Codable {
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

    /// The JSON literal for this id, ready to drop into a hand-built frame.
    var jsonLiteral: String {
        switch self {
        case .number(let value): String(value)
        case .text(let value): JSONValue.string(value).compactJSON
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

// MARK: - Errors

/// The `error` member of a failed response. `data` is kept whole because the server puts
/// structured detail there that no Bloom release has to understand in advance.
public struct CodexRPCError: Sendable, Hashable, Error {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

/// Everything that can go wrong on this connection that is not the server saying no.
public enum CodexClientError: Sendable, Error, Equatable {
    /// The process ended, or was told to end, while requests were still outstanding.
    case connectionClosed(String)
    /// A reply arrived in a shape the caller could not use.
    case unexpectedResult(method: String)
    /// The handshake did not complete, so nothing else may be sent.
    case notInitialized
    /// The server accepted a request and never answered it.
    ///
    /// There was no such case and no such timeout: `CodexClient.send` parked a continuation in
    /// `pending` and waited, so a request the server took and dropped hung its caller until the
    /// process died. Nothing else resumes those continuations except the connection closing.
    case timedOut(method: String, seconds: Int)
}

// MARK: - Frames

public struct CodexServerRequest: Sendable, Hashable {
    public let id: CodexRequestID
    public let method: String
    public let params: JSONValue
    public let raw: Data

    public init(id: CodexRequestID, method: String, params: JSONValue, raw: Data = Data()) {
        self.id = id
        self.method = method
        self.params = params
        self.raw = raw
    }
}

public struct CodexServerNotification: Sendable, Hashable {
    public let method: String
    public let params: JSONValue
    public let raw: Data

    public init(method: String, params: JSONValue, raw: Data = Data()) {
        self.method = method
        self.params = params
        self.raw = raw
    }
}

/// One decoded line off the server.
///
/// Nothing here throws and nothing traps. A line that is not JSON at all comes back as
/// `.malformed` with its bytes intact, because the server writes tracing to stderr and a future
/// release could well write something new to stdout, and neither may end a session.
public enum CodexFrame: Sendable, Hashable {
    case response(id: CodexRequestID, result: JSONValue, raw: Data)
    case failure(id: CodexRequestID, error: CodexRPCError, raw: Data)
    case request(CodexServerRequest)
    case notification(CodexServerNotification)
    case malformed(Data)

    public static func decode(line: String) -> CodexFrame? {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let raw = Data(line.utf8)
        guard let json = JSONValue.parse(raw), case .object = json else { return .malformed(raw) }

        let id = CodexRequestID(json["id"])
        let params = json["params"] ?? .object([:])

        if let method = json["method"]?.stringValue {
            if let id {
                return .request(CodexServerRequest(id: id, method: method, params: params, raw: raw))
            }
            return .notification(CodexServerNotification(method: method, params: params, raw: raw))
        }

        guard let id else { return .malformed(raw) }

        if let error = json["error"] {
            return .failure(
                id: id,
                error: CodexRPCError(
                    code: error["code"]?.intValue ?? 0,
                    message: error["message"]?.stringValue ?? "",
                    data: error["data"]
                ),
                raw: raw
            )
        }

        // A `result` of JSON null is a perfectly good success, and `JSONValue`'s subscript reads
        // null as absent, so the object is looked at directly rather than through it.
        guard case .object(let object) = json, object.keys.contains("result") else {
            return .malformed(raw)
        }
        return .response(id: id, result: object["result"] ?? .null, raw: raw)
    }
}

// MARK: - Outgoing frames

/// Builds the lines Bloom writes to the server's stdin.
///
/// Strings rather than `Encodable` structs, because every one of these carries a `params` object
/// whose members differ per method and are often optional in a way JSON null does not express:
/// `sandbox: null` is not the same request as no `sandbox` at all. `JSONValue.object(omittingNil:)` below
/// drops the absent ones, which is the behaviour the server documents.
public enum CodexOutgoing {
    /// Sent even though the schema has no `jsonrpc` member, because the spec asks for it and the
    /// server ignores what it does not know.
    static let version = "2.0"

    public static func request(id: CodexRequestID, method: String, params: JSONValue?) -> String {
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

    /// The answer to a server-to-client request. This is the half that makes approvals possible,
    /// and the reason a plain NDJSON reader would never do.
    public static func response(id: CodexRequestID, result: JSONValue) -> String {
        "{\"jsonrpc\":\"\(version)\",\"id\":\(id.jsonLiteral),\"result\":\(result.compactJSON)}"
    }

    public static func failure(id: CodexRequestID, code: Int, message: String) -> String {
        let error = JSONValue.object([
            "code": .integer(code),
            "message": .string(message),
        ])
        return "{\"jsonrpc\":\"\(version)\",\"id\":\(id.jsonLiteral),\"error\":\(error.compactJSON)}"
    }
}

// MARK: - JSON helpers

extension JSONValue {
    /// One line of JSON, which is what a line-delimited transport needs. Slashes are left alone so
    /// a path in a prompt stays readable in a log.
    public var compactJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    /// An object built from optional members, where nil means "leave the key out".
    ///
    /// The distinction matters on this protocol: `thread/start` with `sandbox` absent keeps the
    /// configured default, while `sandbox: null` is a value the server rejects for several of its
    /// enums. Every params builder in `CodexClient` goes through here.
    ///
    /// Spelled with a label rather than overloading the `object` case, so a dictionary literal is
    /// never ambiguous between the two.
    public static func object(omittingNil entries: [String: JSONValue?]) -> JSONValue {
        .object(entries.compactMapValues { $0 })
    }
}
