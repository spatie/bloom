import Foundation

/// The MCP server, on Bloom's side of the socket.
///
/// The shim relays lines and knows nothing about MCP, so `initialize`, `tools/list` and
/// `tools/call` are all answered here, where the store is reachable and where an update can change
/// them without the binary in the bundle having to agree.
///
/// One connection is one caller, so the identity is fixed for the life of a dispatch. Nothing in a
/// frame can change who is calling.
public struct BridgeDispatch: Sendable {
    private let store: Store
    private let toolbox: BridgeToolbox
    private let identity: BridgeIdentity

    public init(store: Store, identity: BridgeIdentity, toolbox: BridgeToolbox = .standard) {
        self.store = store
        self.identity = identity
        self.toolbox = toolbox
    }

    /// What Bloom calls itself in `serverInfo`. The version is the socket protocol's, not the
    /// app's: it is the number that decides whether the two halves understand each other, and a
    /// build number here would tell a reader nothing they could act on.
    public static let serverVersion = "\(BridgeProtocol.version).0.0"

    /// The reply to one line, or nil when the line was a notification and must be answered with
    /// silence.
    public func respond(to line: String) async -> String? {
        guard let request = MCPRequest.decode(line) else {
            // A line that is not a request has no id to answer against, so there is nobody to tell.
            // Dropping it is what the specification asks for and is also the only thing that can
            // be done.
            return nil
        }
        guard let response = await respond(to: request) else { return nil }
        return response.line()
    }

    public func respond(to request: MCPRequest) async -> MCPResponse? {
        // Answered before the id check, because a notification with a method we handle is still a
        // notification: `notifications/initialized` is the client saying it is ready and expects
        // nothing back.
        guard let id = request.id, id != .null else { return nil }

        switch request.method {
        case "initialize":
            return .result(id: id, initialize(request))
        case "ping":
            // Some clients use it as a liveness check with a timeout behind it, so it is answered
            // rather than left to fall through to method-not-found.
            return .result(id: id, .object([:]))
        case "tools/list":
            let tools = toolbox.tools(for: identity.role).map(\.listing)
            return .result(id: id, .object(["tools": .array(tools)]))
        case "tools/call":
            return await callTool(request, id: id)
        default:
            return .failure(
                id: id,
                code: MCPErrorCode.methodNotFound,
                message: "\(BridgeRegistration.serverName) does not implement \(request.method)"
            )
        }
    }

    /// The protocol version is echoed back rather than negotiated.
    ///
    /// This server has no version-dependent behaviour: three methods, one tool, text results.
    /// Naming a version of our own would mean picking one the client might not know, and the whole
    /// point of the handshake that already ran on this socket is that version skew is Bloom's
    /// problem to detect, not MCP's. A client that asked for a version it does not support is not
    /// a case that exists.
    private func initialize(_ request: MCPRequest) -> JSONValue {
        let requested = request.param("protocolVersion")
        return .object([
            "protocolVersion": requested ?? .string("2025-06-18"),
            "capabilities": .object(["tools": .object([:])]),
            "serverInfo": .object([
                "name": .string(BridgeRegistration.serverName),
                "version": .string(Self.serverVersion),
            ]),
        ])
    }

    private func callTool(_ request: MCPRequest, id: JSONValue) async -> MCPResponse {
        guard let name = request.stringParam("name") else {
            return .failure(
                id: id,
                code: MCPErrorCode.invalidParams,
                message: "tools/call needs a tool name"
            )
        }
        guard let handler = toolbox.handler(named: name, for: identity.role) else {
            // Not-found rather than a refusal, and the same answer for "no such tool" and "not
            // yours". A caller that is told a tool exists but is refused has been told something,
            // and there is nothing here worth telling.
            return .failure(
                id: id,
                code: MCPErrorCode.methodNotFound,
                message: "\(BridgeRegistration.serverName) has no tool called \(name)"
            )
        }
        // `arguments` rather than `params` is what a tool sees, so the handler is handed a request
        // whose params ARE the arguments. Without this every tool would have to remember to
        // unwrap, and the one that forgot would read every argument as nil and do nothing quietly.
        let call = MCPRequest(id: request.id, method: name, params: request.param("arguments"))
        let result = await handler.call(call, as: identity, store: store)
        return .result(id: id, result.content)
    }
}
