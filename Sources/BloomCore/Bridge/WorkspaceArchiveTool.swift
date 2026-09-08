import Foundation

/// Returned only after the normal archive lifecycle has completed or refused the request.
public enum WorkspaceArchiveOutcome: Sendable, Equatable {
    case archived
    case refused(String)
}

public typealias WorkspaceArchiving = @Sendable (Workspace) async -> WorkspaceArchiveOutcome

/// The owner's explicit cleanup request. The app retains the branch and applies the same
/// live-agent and filesystem checks as the Archive command, with no force option.
public struct WorkspaceArchiveTool: BridgeToolHandling {
    private let archive: WorkspaceArchiving

    public init(_ archive: @escaping WorkspaceArchiving) {
        self.archive = archive
    }

    public let roles: Set<BridgeRole> = [.owner]

    public let tool = BridgeTool(
        name: "workspace_archive",
        description: """
            Archive a workspace when the owner asks to clean it up. Pass its exact 'id' from \
            workspace_list. This removes the worktree and closes its terminals and dev servers. \
            Its branch, notes and chat history are kept, and the workspace moves to Archived.

            The normal archive script runs if the project has one. A running agent, uncommitted \
            changes, local files that would be lost, or a failed safety check refuses the call. \
            There is no force option. Explain a refusal to the owner and let them resolve it or \
            archive manually in Bloom. Do not discard files just to make this tool succeed.

            Only call after the owner has asked for the workspace to be archived. The result \
            confirms completion, not a queued request. An already archived workspace is a no-op.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object([
                    "type": .string("string"),
                    "description": .string("The exact workspace id returned by workspace_list."),
                ]),
            ]),
            "required": .array([.string("id")]),
            "additionalProperties": .bool(false),
        ])
    )

    public func call(
        _ request: MCPRequest, as identity: BridgeIdentity, store: Store
    ) async -> BridgeToolResult {
        guard identity.role == .owner else {
            return .failure("Only the owner's connection can archive workspaces.")
        }
        guard case .object(let arguments)? = request.params,
              Set(arguments.keys) == ["id"],
              let rawID = request.stringParam("id")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawID.isEmpty else {
            return .failure("Pass only 'id', using the exact workspace id from workspace_list. There is no force option.")
        }
        let workspace: Workspace
        do {
            guard let found = try await store.workspace(id: WorkspaceID(rawID)) else {
                return .failure("No workspace has that id. Call workspace_list and use the id it reports.")
            }
            workspace = found
        } catch {
            return .failure("Bloom could not read this workspace. Nothing was archived; try again shortly.")
        }
        if workspace.state == .archived {
            return BridgeToolResult(text: "'\(workspace.name)' is already archived. Nothing changed.")
        }
        do {
            if workspace.setupState == .running {
                return .failure("Workspace setup is still running. Wait for it to finish before archiving.")
            }
            for session in try await store.sessions(workspaceID: workspace.id) {
                if session.state == .running || session.state == .waiting {
                    return .failure("An agent is running or awaiting an answer in this workspace. Finish or stop it before archiving.")
                }
                if try await !store.pendingDeliveries(sessionID: session.id).isEmpty {
                    return .failure("This workspace has queued messages. Handle them before archiving.")
                }
            }
        } catch {
            return .failure("Bloom could not check this workspace's activity. Nothing was archived; try again shortly.")
        }
        switch await archive(workspace) {
        case .archived:
            return BridgeToolResult(text: "Archived '\(workspace.name)'. Its branch, notes and chat history were kept.")
        case .refused(let reason):
            return .failure("The archive request was refused. \(reason)")
        }
    }
}
