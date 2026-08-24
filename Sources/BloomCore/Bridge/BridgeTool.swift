import Foundation

/// One tool as `tools/list` describes it.
///
/// The description is not documentation. It is the only thing the model reads before deciding
/// whether to call, so it says what the tool does, what it costs and what it refuses, in the same
/// register a good API doc would.
public struct BridgeTool: Sendable, Hashable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    /// A schema for a tool that takes nothing.
    ///
    /// `properties` is present and empty rather than absent: a client that validates against the
    /// schema before sending needs the object type stated, and one that renders the tool needs
    /// something to render nothing from.
    public static let noArguments = JSONValue.object([
        "type": .string("object"),
        "properties": .object([:]),
        "required": .array([]),
    ])

    public var listing: JSONValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": inputSchema,
        ])
    }
}

/// What a tool answers with.
///
/// A refusal is a result with `isError` set, not a JSON-RPC error frame. The difference matters:
/// a JSON-RPC error is a transport failure the CLI may retry or surface as a broken server, while
/// an errored result is text the model reads and can act on. "You are not allowed to archive that
/// workspace" is something to tell the model, not something to tell the transport.
public struct BridgeToolResult: Sendable, Hashable {
    public let text: String
    public let isError: Bool

    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }

    public static func failure(_ text: String) -> BridgeToolResult {
        BridgeToolResult(text: text, isError: true)
    }

    /// A structured answer, rendered for a reader rather than for a parser.
    ///
    /// MCP carries a tool result as text, and the text goes straight into the model's context, so
    /// it is pretty printed with sorted keys: sorted so two calls a turn apart do not look like a
    /// change when they are not, and indented because the model reads it and a single line of
    /// nested JSON is the thing it reads worst.
    public static func json(_ value: JSONValue) -> BridgeToolResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else {
            return .failure("Bloom could not render this answer as JSON.")
        }
        return BridgeToolResult(text: String(decoding: data, as: UTF8.self))
    }

    public var content: JSONValue {
        .object([
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "isError": .bool(isError),
        ])
    }
}

/// One tool, its role gate and its implementation.
///
/// The role gate is on the handler rather than in the dispatch, so a tool arrives with the answer
/// to "who can call this" attached. It is enforced twice on purpose: `tools/list` hides what the
/// caller may not use, so a child never sees a spawn tool to be tempted by, and `tools/call`
/// refuses it again, so a process speaking raw MCP at the socket with a child's token gets
/// nowhere either.
public protocol BridgeToolHandling: Sendable {
    var tool: BridgeTool { get }
    var roles: Set<BridgeRole> { get }

    /// The store is passed in rather than held, because there is exactly one `Store` instance in
    /// the app and a handler that opened its own would be a second SQLite connection on the file.
    /// The cross-connection sequence race is what `UNIQUE(session_id, seq)` and the retry in
    /// `appendNext` exist to survive rather than to invite.
    func call(_ request: MCPRequest, as identity: BridgeIdentity, store: Store) async -> BridgeToolResult
}
