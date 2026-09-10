import Foundation

/// Chat discovery belongs to the store: reading a conversation must work without selecting its
/// tab or loading its transcript into the window. IDs disambiguate chats with the same title.
public struct ChatListTool: BridgeToolHandling {
    public init() {}

    public let roles = BridgeWorkspaceScope.roles
    public let tool = BridgeTool(
        name: "chat_list",
        description: """
            List the unarchived chats in your workspace, including subagents: their IDs, titles, \
            agents, states and message counts. 'current' identifies your own chat. Use chat_read \
            with an ID or an exact title to read a conversation without selecting its tab.
            This reads stored data and does not open, select or change anything.
            """,
        inputSchema: BridgeTool.noArguments
    )

    public func call(_ request: MCPRequest, as identity: BridgeIdentity, store: Store) async -> BridgeToolResult {
        guard let workspaceID = identity.workspaceID else {
            return .failure(BridgeWorkspaceScope.refusal(tool: "chat_list", doing: "lists the chats in"))
        }
        do {
            let sessions = try await store.sessions(workspaceID: workspaceID)
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
            return .json(.object(["chats": .array(chats), "count": .integer(chats.count)]))
        } catch {
            return .failure("Bloom could not list the chats: \(error.localizedDescription)")
        }
    }

    static func title(of session: Session) -> String {
        session.title.isEmpty ? PaneNaming.untitledChat : session.title
    }
}
