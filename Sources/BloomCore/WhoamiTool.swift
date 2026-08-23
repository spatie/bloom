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

    public let roles: Set<BridgeRole> = [.parent, .child, .owner]

    public let tool = BridgeTool(
        name: "whoami",
        description: """
            What this connection is: which copy of Bloom is at the other end of it, and which \
            workspace it is speaking for, if any. Inside a Bloom workspace that is the workspace \
            and its branch, the worktree path, the project it belongs to, and whether the \
            workspace was created by the owner or by another agent. From a client of the owner's \
            own it is the copy of Bloom you have reached and how much it is holding, which is the \
            cheapest way to confirm the connection works before asking it for anything real.

            Takes no arguments, because Bloom already knows who is calling. Read only.
            """,
        inputSchema: BridgeTool.noArguments
    )

    public func call(
        _ request: MCPRequest,
        as identity: BridgeIdentity,
        store: Store
    ) async -> BridgeToolResult {
        guard let workspaceID = identity.workspaceID else { return await owner(store: store) }
        do {
            guard let workspace = try await store.workspace(id: workspaceID) else {
                // Reachable: a workspace archived and removed while its agent was mid-turn. The
                // model is told plainly rather than handed an empty object to misread.
                return .failure("This workspace is no longer in Bloom's database.")
            }
            var session: Session?
            if let sessionID = identity.sessionID {
                session = try await store.session(id: sessionID)
            }
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
                    "id": .string(identity.sessionID?.rawValue ?? ""),
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
            case .ownerClient:
                // The owner, through a tool rather than through the sheet. "owner" and not
                // something finer, because who asked is the question and the answer is the same
                // person; which door they came through is Bloom's business, not the agent's.
                answer["created_by"] = .string("owner")
            }
            return .json(.object(answer))
        } catch {
            return .failure("Bloom could not read this workspace: \(error.readableMessage)")
        }
    }

    /// The answer for the owner's own client, which is a different question wearing the same name.
    ///
    /// A workspace agent asks "who am I" and already knows the answer is a workspace; what it
    /// wants is which one. A client outside Bloom asks it to find out whether it reached anything
    /// at all, and if so which copy: the owner runs Bloom and Bloom Dev at once, both listening on
    /// their own socket, and a configuration pointing at the wrong one behaves perfectly and does
    /// its work in the wrong database. So this names the database, which is the one thing that
    /// tells the two apart, and then says how much is in it, which is how a person recognises it.
    private func owner(store: Store) async -> BridgeToolResult {
        do {
            let projects = try await store.repos()
            let running = try await store.workspaces()
            return .json(.object([
                "role": .string(BridgeRole.owner.rawValue),
                "connected_to": .object([
                    "app": .string("Bloom"),
                    "database": .string(store.path),
                    "bridge_protocol": .integer(BridgeProtocol.version),
                ]),
                "projects": .integer(projects.count),
                "workspaces": .integer(running.count),
                "note": .string(
                    "You are talking to Bloom as its owner, from outside any workspace. You can "
                        + "list projects, register an existing repository as one, and start "
                        + "workspaces in them."
                ),
            ]))
        } catch {
            return .failure("Bloom could not read its own database: \(error.readableMessage)")
        }
    }
}
