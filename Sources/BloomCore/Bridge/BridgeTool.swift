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
    /// A picture, for the one tool that has one. Nil for every other result, which is why it is
    /// defaulted rather than threaded through eighteen call sites that have nothing to say about
    /// it.
    public let image: BridgeToolImage?

    public init(text: String, isError: Bool = false, image: BridgeToolImage? = nil) {
        self.text = text
        self.isError = isError
        self.image = image
    }

    /// An image, and the sentence that says what it is of.
    ///
    /// The text is not decoration. A model handed a bare image has to work out from the
    /// conversation what it is looking at, and the one fact it cannot see in the picture is which
    /// pane and which address it came from.
    public static func picture(_ image: BridgeToolImage, saying text: String) -> BridgeToolResult {
        BridgeToolResult(text: text, isError: false, image: image)
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

    /// The MCP shape: a list of content blocks, text first.
    ///
    /// An image travels as its own block rather than as a data URI inside the text, because that
    /// is what the protocol says and because the two CLIs render a block and would render a
    /// hundred kilobytes of base64 in a sentence as a hundred kilobytes of base64 in a sentence.
    public var content: JSONValue {
        var blocks: [JSONValue] = [.object(["type": .string("text"), "text": .string(text)])]
        if let image { blocks.append(image.content) }
        return .object([
            "content": .array(blocks),
            "isError": .bool(isError),
        ])
    }
}

/// A picture a tool answers with.
///
/// It exists for `browser_screenshot` and is written to be the only way an image reaches the wire,
/// so the size ceiling below is enforced in one place rather than remembered in each.
public struct BridgeToolImage: Sendable, Hashable {
    public let data: Data
    public let mimeType: String

    /// What one result may carry.
    ///
    /// The socket does not care: `UnixSocketConnection` writes a line of any length and
    /// `LineBuffer` reads one. The model does. Base64 is a third larger than the bytes, every one
    /// of those bytes is a token the owner pays for, and a picture of a web page that will not fit
    /// in this is a picture of a page nobody wanted at that size. `BrowserSnapshot.agentWidth` is
    /// the other half of that argument, and is what keeps a real capture an order of magnitude
    /// under it.
    public static let maximumBytes = 4 * 1_024 * 1_024

    public init(png: Data) {
        data = png
        mimeType = "image/png"
    }

    /// Whether this is small enough to send, asked by the tool rather than by the initialiser, so
    /// that the refusal is a sentence a model reads rather than a nil somebody has to explain.
    public var isTooLarge: Bool { data.count > Self.maximumBytes }

    var content: JSONValue {
        .object([
            "type": .string("image"),
            "data": .string(data.base64EncodedString()),
            "mimeType": .string(mimeType),
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
