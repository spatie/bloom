import Foundation

/// The tool that proves the pipe.
///
/// It answers the question no tool after it will ever ask: who is calling. Identity is minted by
/// Bloom and carried in the shim's environment, so the chain the bridge has to get right is token
/// to session to workspace to project, and this is that chain read out loud. Every tool that
/// follows depends on it and none of them will expose it, because they take no workspace id
/// either.
///
/// It also earns its place past phase one. An agent that can see the branch it is on and the
/// worktree it is in stops guessing at both from `git` output and a `pwd`, and a child that is
/// about to be told "you were spawned by workspace X" has somewhere to check that against.
public struct WhoamiTool: BridgeToolHandling {
    public init() {}

    public let roles: Set<BridgeRole> = [.parent, .child]

    public let tool = BridgeTool(
        name: "whoami",
        description: """
            Which Bloom workspace this conversation is running in: the workspace and its branch, \
            the worktree path, the project it belongs to, and whether this workspace was created \
            by the owner or by another agent. Takes no arguments, because Bloom already knows \
            which chat is calling. Cheap and read only.
            """,
        inputSchema: BridgeTool.noArguments
    )

    public func call(
        _ request: MCPRequest,
        as identity: BridgeIdentity,
        store: Store
    ) async -> BridgeToolResult {
        do {
            guard let workspace = try await store.workspace(id: identity.workspaceID) else {
                // Reachable: a workspace archived and removed while its agent was mid-turn. The
                // model is told plainly rather than handed an empty object to misread.
                return .failure("This workspace is no longer in Bloom's database.")
            }
            let session = try await store.session(id: identity.sessionID)
            let repo = try await store.repo(id: workspace.repoID)

            var answer: [String: JSONValue] = [
                "role": .string(identity.role.rawValue),
                "workspace": .object([
                    "id": .string(workspace.id.rawValue),
                    "name": .string(workspace.name),
                    "branch": .string(workspace.branch),
                    "base_branch": .string(workspace.baseBranch),
                    "path": .string(workspace.path),
                    "state": .string(workspace.state.rawValue),
                ]),
                "session": .object([
                    "id": .string(identity.sessionID.rawValue),
                    "title": .string(session?.title ?? ""),
                    "agent": .string((session?.agentKind ?? .claudeCode).rawValue),
                ]),
            ]
            if let repo {
                answer["project"] = .object([
                    "id": .string(repo.id.rawValue),
                    "name": .string(repo.name),
                    "path": .string(repo.path),
                    "default_branch": .string(repo.defaultBranch),
                ])
            }
            switch workspace.origin {
            case .user:
                answer["created_by"] = .string("owner")
            case .agent(let parentWorkspaceID, let spawnToolUseID):
                answer["created_by"] = .object([
                    "agent_in_workspace": .string(parentWorkspaceID.rawValue),
                    "spawn_tool_use_id": .string(spawnToolUseID),
                ])
            }
            return .json(.object(answer))
        } catch {
            return .failure("Bloom could not read this workspace: \(error.readableMessage)")
        }
    }
}
