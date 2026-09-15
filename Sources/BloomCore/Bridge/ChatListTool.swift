import Foundation

/// Chat discovery belongs to the store: reading a conversation must work without selecting its
/// tab or loading its transcript into the window. IDs disambiguate chats with the same title.
///
/// It lists the caller's own workspace unless another is named, and the owner's own client has to
/// name one. See `BridgeReadTarget` for why a read may cross into another workspace when nothing
/// else a parent has may.
public struct ChatListTool: BridgeToolHandling {
    public init() {}

    public let roles: Set<BridgeRole> = [.workspace, .owner]
    public let tool = BridgeTool(
        name: "chat_list",
        description: """
            List the unarchived chats in a workspace, including subagents: their IDs, titles, \
            agents, states and message counts. Use chat_read with an ID or an exact title to read \
            a conversation without selecting its tab.

            Without 'workspace' it lists your own workspace, and 'current' identifies your own \
            chat. Pass 'workspace' with an id from workspace_list, or a name no other active \
            workspace shares, to list another workspace's chats; the answer then names that \
            workspace and no chat in it is 'current'. A client that is not working in a workspace \
            must pass it.

            This reads stored data and does not open, select or change anything.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([BridgeReadTarget.argument: BridgeReadTarget.schemaProperty]),
            "required": .array([]),
        ])
    )

    public func call(_ request: MCPRequest, as identity: BridgeIdentity, store: Store) async -> BridgeToolResult {
        do {
            let target: BridgeReadTarget
            switch try await BridgeReadTarget.resolve(request, as: identity, store: store) {
            case .failure(let trouble): return .failure(trouble.sentence(tool: "chat_list"))
            case .success(let resolved): target = resolved
            }
            let sessions = try await store.sessions(workspaceID: target.workspaceID)
            var chats: [JSONValue] = []
            for session in sessions {
                let count = try await store.messageCount(sessionID: session.id)
                chats.append(.object([
                    "id": .string(session.id.rawValue),
                    "title": .string(Self.title(of: session)),
                    "agent": .string(session.agentKind.rawValue),
                    "state": .string(session.state.rawValue),
                    "current": .bool(session.id == identity.sessionID),
                    "parent_chat_id": session.parentSessionID.map { .string($0.rawValue) } ?? .null,
                    "messages": .integer(count),
                ]))
            }
            var answer: [String: JSONValue] = ["chats": .array(chats), "count": .integer(chats.count)]
            if case .named(let workspace) = target {
                answer["workspace_id"] = .string(workspace.id.rawValue)
                answer["workspace"] = .string(workspace.name)
            }
            return .json(.object(answer))
        } catch {
            return .failure("Bloom could not list the chats: \(error.localizedDescription)")
        }
    }

    static func title(of session: Session) -> String {
        session.title.isEmpty ? PaneNaming.untitledChat : session.title
    }
}
