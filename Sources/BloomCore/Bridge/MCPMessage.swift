import Foundation

/// One JSON-RPC 2.0 frame off the bridge socket, which is one line of MCP the CLI wrote.
///
/// The id is carried as a `JSONValue` and handed straight back rather than parsed into anything.
/// JSON-RPC allows a string, a number or null, the two CLIs do not agree on which they use, and a
/// reply carrying a number where the request carried a string is a reply the client never matches
/// up. The same rule the store already follows for the agent protocols: an opaque token Bloom
/// receives and returns without looking inside.
public struct MCPRequest: Sendable, Hashable {
    public let id: JSONValue?
    public let method: String
    public let params: JSONValue?

    public init(id: JSONValue?, method: String, params: JSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }

    /// A frame with no id expects no reply and must not get one. Sending a response to a
    /// notification is a protocol error the client is entitled to log or close the connection over.
    public var isNotification: Bool { id == nil || id == .null }

    public static func decode(_ line: String) -> MCPRequest? {
        guard let data = line.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let fields) = value,
              case .string(let method)? = fields["method"]
        else { return nil }
        return MCPRequest(id: fields["id"], method: method, params: fields["params"])
    }

    /// One named argument out of `params`, for the handlers.
    public func param(_ name: String) -> JSONValue? {
        guard case .object(let fields)? = params else { return nil }
        return fields[name]
    }

    public func stringParam(_ name: String) -> String? {
        guard case .string(let value)? = param(name) else { return nil }
        return value
    }
}

/// What goes back on the wire.
public struct MCPResponse: Sendable, Hashable {
    public let id: JSONValue
    public let payload: JSONValue

    private init(id: JSONValue, payload: JSONValue) {
        self.id = id
        self.payload = payload
    }

    public static func result(id: JSONValue, _ value: JSONValue) -> MCPResponse {
        MCPResponse(id: id, payload: .object(["result": value]))
    }

    public static func failure(id: JSONValue, code: Int, message: String) -> MCPResponse {
        MCPResponse(id: id, payload: .object([
            "error": .object(["code": .integer(code), "message": .string(message)]),
        ]))
    }

    public func line() -> String {
        var fields: [String: JSONValue] = ["jsonrpc": .string("2.0"), "id": id]
        if case .object(let payload) = payload {
            for (key, value) in payload { fields[key] = value }
        }
        let data = (try? JSONEncoder().encode(JSONValue.object(fields)))
            // Unreachable for a document built out of `JSONValue`, which has no case that fails to
            // encode. Answered with a frame rather than a crash anyway, because the alternative to
            // a malformed reply is a turn that hangs on a tool that never answered.
            ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"unencodable"}}"#.utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// The JSON-RPC codes this server actually sends. Named rather than written out at each site,
/// because -32601 and -32602 are one keystroke apart and mean opposite things to a client that
/// retries.
public enum MCPErrorCode {
    public static let invalidRequest = -32_600
    public static let methodNotFound = -32_601
    public static let invalidParams = -32_602
    public static let internalError = -32_603
}
