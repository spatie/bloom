import Foundation

/// Which workspace a read names: the caller's own, or one it named out loud.
///
/// ## Why reading crosses the edge of a worktree
///
/// `chat_list` and `chat_read` began scoped to the caller's own workspace, on the same gate as the
/// pane tools. That gate exists because those tools act on the window the caller is standing in,
/// and a read changes nothing in anybody's window. What it cost was real: an agent told "look at
/// what the other workspace decided about the index" had no way to find out, and an agent asked to
/// review another workspace's branch had to be handed a worktree path and told to run git in it
/// with `Bash`, which is further out than this and goes through no gate of Bloom's at all. Every
/// agent here works for the same owner, and `workspace_say` already lets an agent put a turn in
/// another workspace's chat, which is a far heavier thing than reading one.
///
/// ## Who may name one
///
/// `.workspace` may leave it out, and gets its own workspace, exactly as before the widening.
/// `.owner` must name one, because that client is sitting in no workspace and nothing can be
/// implied on its behalf.
///
/// ## Why this is not `WorkspaceSayTool.target(named:store:)`
///
/// It is the same resolution, over the same `BridgeWorkspaceLookup`, and one function would be
/// better. That function answers in `WorkspaceSayTrouble`, whose sentences name `workspace_say`,
/// so the lookup is written a second time here in its smallest form. Now that the child narrowing
/// is gone from that side, the two are the same function and the obvious place to fold together.
public enum BridgeReadTarget: Sendable, Equatable {
    /// The workspace the caller's token speaks for. Only the id, because the chat tools need
    /// nothing else and did not read the row before this existed.
    case own(WorkspaceID)
    /// A workspace the caller named, which may still turn out to be its own.
    case named(Workspace)

    public var workspaceID: WorkspaceID {
        switch self {
        case .own(let id): return id
        case .named(let workspace): return workspace.id
        }
    }

    /// The key the argument is read from, on every tool that takes one.
    static let argument = "workspace"

    /// The property to put in a tool's input schema, so every tool describes it in the same words.
    static let schemaProperty: JSONValue = .object([
        "type": .string("string"),
        "description": .string(
            "Another workspace to read, by the id workspace_list or workspace_start reports, or by "
                + "its name when no other active workspace shares it. Leave it out to read your own. "
                + "Required from a client that is not working in a workspace."
        ),
    ])

    /// Resolves the `workspace` argument of `request` for `identity`.
    static func resolve(
        _ request: MCPRequest, as identity: BridgeIdentity, store: Store
    ) async throws -> Result<BridgeReadTarget, BridgeReadTrouble> {
        var given: String?
        // A null is a model spelling "leave it out", and is read as that.
        if let raw = request.param(argument), raw != .null {
            guard let text = raw.stringValue else { return .failure(.notText) }
            given = AgentStartTool.text(text)
        }

        guard let given else {
            guard let own = identity.workspaceID else { return .failure(.noWorkspaceNamed) }
            return .success(.own(own))
        }

        let all = try await store.workspaces(includeArchived: true)
        let active = all.filter { $0.state != .archived }
        switch BridgeWorkspaceLookup.find(given, among: active) {
        case .found(let workspace):
            return .success(.named(workspace))
        case .ambiguous(let matches):
            return .failure(.ambiguous(given: given, ids: matches.map(\.id.rawValue)))
        case .unknown:
            // Looked through only to say so: a workspace archived since the caller last listed
            // them is a better refusal than "no such workspace".
            if case .found(let archived) = BridgeWorkspaceLookup.find(given, among: all) {
                return .failure(.archived(name: archived.name))
            }
            return .failure(.unknown(given: given, known: active.map(\.name)))
        }
    }
}

/// Why a read would not say which workspace it means, in terms a model can act on.
public enum BridgeReadTrouble: Error, Sendable, Equatable {
    case notText
    case noWorkspaceNamed
    case unknown(given: String, known: [String])
    case ambiguous(given: String, ids: [String])
    case archived(name: String)

    /// `tool` is the tool's own name, so the sentence says which call it is about.
    public func sentence(tool: String) -> String {
        switch self {
        case .notText:
            return "\(tool) takes 'workspace' as a string: a workspace id or name. Leave it out to read your own."

        case .noWorkspaceNamed:
            return """
                \(tool) needs to be told which workspace to read, because this connection is not \
                working in one. Pass 'workspace' with the id workspace_list reports, or a name no \
                other workspace shares.
                """

        case let .unknown(given, known):
            return """
                Bloom has no active workspace called '\(given)'. Active workspaces: \
                \(BridgeWorkspaceLookup.list(known)). Retrying with the same name will fail the \
                same way, so pass an id workspace_list reports.
                """

        case let .ambiguous(given, ids):
            return """
                More than one workspace is called '\(given)', so Bloom will not guess which you \
                meant. Pass one of these ids instead: \(BridgeWorkspaceLookup.list(ids)).
                """

        case .archived(let name):
            return """
                The workspace '\(name)' has been archived, so \(tool) has nothing there to read. \
                Retrying will not change that.
                """
        }
    }
}
