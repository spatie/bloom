import Foundation

/// What became of an archive request.
///
/// `archived` is only returned after the normal archive lifecycle has completed. `requested` is
/// the answer to a workspace's own agent and is deliberately a third case rather than a success
/// with a hedge in its sentence: the caller is mid turn, nothing has been removed, and a model
/// handed `archived` would go on to tell the owner that a worktree it is still standing in has
/// gone.
public enum WorkspaceArchiveOutcome: Sendable, Equatable {
    case archived
    /// Booked, and it runs when the asking turn ends. See `WorkspaceArchiveOrder.afterTurnOf`.
    case requested
    case refused(String)
}

/// Who is asking, which is the whole of what the app needs to know to decide when to act.
///
/// The session rather than a flag, because the app has to wait for one particular turn to end and
/// a workspace holds several chats at once. A boolean would have it archive on whichever chat
/// happened to finish first, which in a workspace running a crew is not the one that asked.
public struct WorkspaceArchiveOrder: Sendable, Hashable {
    public let workspace: Workspace
    /// The chat whose turn has to end before the worktree can go, or nil for the owner's own
    /// client, which is sitting in no turn and can be acted on at once.
    public let afterTurnOf: SessionID?

    public init(workspace: Workspace, afterTurnOf: SessionID?) {
        self.workspace = workspace
        self.afterTurnOf = afterTurnOf
    }
}

public typealias WorkspaceArchiving = @Sendable (WorkspaceArchiveOrder) async -> WorkspaceArchiveOutcome

/// `workspace_archive`: clean a workspace up, keeping everything that exists nowhere else.
///
/// ## Who may call it, and on which workspace
///
/// `.owner` and `.workspace`, exactly as `workspace_rename` is, and for the same reasons.
///
/// The owner's client names a workspace out loud, because it is sitting in none and nothing else
/// says which.
///
/// A workspace agent archives its own by naming none, and the token says which workspace that
/// is. It may also name, by id, **a workspace it started** with `workspace_start`, and no other.
/// That is the case that forced the widening: a workspace hands a job to another, the other
/// reports back, and the one that asked is the one that knows the job is done. Before, the agent
/// that was asked to clean up could not (it was a child, and children did nothing), and the agent
/// that started it could not either (it could only name itself), so the worktree stayed until a
/// person archived it by hand. Parentage is read off the row, `WorkspaceOrigin.parentWorkspaceID`,
/// which is written once when the workspace is started and cannot be claimed by a caller.
///
/// Any workspace it did not start is refused with the same sentence whether it exists or not, so
/// the refusal does not confirm which ids are real.
///
/// ## Why a workspace agent's call on its own workspace is a request rather than an archive
///
/// The agent is inside the worktree that would be removed. `git worktree remove --force`
/// unlinking files under a running agent is how work gets corrupted rather than merely lost, which
/// is why `AppModel.performArchive` stops the agents first, and stopping the agent that is waiting
/// on this tool call means killing the turn that made it. So the call is booked and the tool says
/// so: the safety check runs again once that turn has ended, with nothing excused, and the archive
/// runs then. The answer says "requested" in those words because a model that reads it as done
/// tells the owner something that has not happened yet, and because there is nothing left for it
/// to say afterwards: whatever it was keeping back is keeping back for ever.
///
/// A refusal after the fact reaches the owner rather than the agent, because by then there is no
/// agent to reach. See `AppModel.archiveIfRequested`.
///
/// Archiving a workspace it started is not deferred: the caller is standing in a different
/// worktree, so nothing it is waiting on is removed, and the safety check runs with nothing
/// excused. A turn still running over there refuses it, which is the right answer, because that
/// agent is not done.
///
/// ## Why it is not self-approved
///
/// It removes a worktree, and `BridgeToolApproval`'s own head names it as the example of what is
/// deliberately off that list: a tool that can lose work is a tool a person answers for. Deferring
/// the cleanup does not change that, and the ask lands in front of the owner while the agent is
/// still running, which is the one moment they can still say no.
public struct WorkspaceArchiveTool: BridgeToolHandling {
    private let archive: WorkspaceArchiving

    public init(_ archive: @escaping WorkspaceArchiving) {
        self.archive = archive
    }

    public let roles: Set<BridgeRole> = [.owner, .workspace]

    public let tool = BridgeTool(
        name: "workspace_archive",
        description: """
            Archive a workspace that is finished with. This removes the worktree and closes its \
            terminals and dev servers. Its branch, notes and chat history are kept, and the \
            workspace moves to Archived.

            If you are working in a workspace, pass nothing to archive your own. You are still \
            running, so the worktree cannot go yet. The call is a request: Bloom checks again once \
            your turn has ended and archives then. Say everything you have to say in this same \
            turn, because there will not be another one, and do not report the workspace as \
            archived. Only ask when the work is done and the owner, or the workspace that started \
            yours, has said the workspace can go.

            To archive a workspace you started with workspace_start, pass 'id' with the id \
            workspace_start reported. Only a workspace you started can be named; any other is \
            refused. It is archived at once if its agent has finished, so call it after that \
            workspace has reported back, not while it is still working.

            From a client of the owner's own, pass 'id' with the exact workspace id from \
            workspace_list. Only call after the owner has asked for that workspace to be archived.

            The normal archive script runs if the project has one. Another agent running, queued \
            messages, uncommitted changes, local files that would be lost, or a failed safety \
            check refuses the call. There is no force option and no way to delete the branch. \
            Explain a refusal and let the owner resolve it or archive manually in Bloom. Do not \
            discard files just to make this tool succeed. An already archived workspace is a no-op.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object([
                    "type": .string("string"),
                    "description": .string(
                        "The exact workspace id. From the owner's own client, any id "
                            + "workspace_list returns. From an agent working in a workspace, only "
                            + "the id of a workspace it started with workspace_start; leave it out "
                            + "to archive your own."
                    ),
                ]),
            ]),
            "additionalProperties": .bool(false),
        ])
    )

    public func call(
        _ request: MCPRequest, as identity: BridgeIdentity, store: Store
    ) async -> BridgeToolResult {
        let workspace: Workspace
        let asking: SessionID?
        switch await find(request, as: identity, store: store) {
        case .refused(let sentence): return .failure(sentence)
        case .found(let found, let session): (workspace, asking) = (found, session)
        }

        if workspace.state == .archived {
            return BridgeToolResult(text: "'\(workspace.name)' is already archived. Nothing changed.")
        }
        if let objection = await WorkspaceArchiveSafety.objection(
            to: workspace, excusing: asking, store: store
        ) {
            return .failure(objection)
        }

        switch await archive(WorkspaceArchiveOrder(workspace: workspace, afterTurnOf: asking)) {
        case .archived:
            return BridgeToolResult(text: "Archived '\(workspace.name)'. Its branch, notes and chat history were kept.")
        case .requested:
            return BridgeToolResult(text: """
                Archiving '\(workspace.name)' is requested, not done. Nothing has been removed and \
                you are still in the worktree. Bloom checks again when this turn ends, and \
                archives then if no agent is running here and nothing is queued; if it refuses, \
                the workspace stays and the owner is told why. This is your last turn in this \
                workspace, so finish what you were saying now, and do not report it as archived.
                """)
        case .refused(let reason):
            return .failure("The archive request was refused. \(reason)")
        }
    }

    /// Which workspace this call is about, and whose turn it is being made from.
    private enum Subject {
        /// The workspace, and the chat that must finish first when a workspace agent is asking.
        case found(Workspace, SessionID?)
        case refused(String)
    }

    /// Which workspace this call is about and whose turn it is being made from, or why there is
    /// neither. The two arms are the two roles and they do not overlap.
    private func find(
        _ request: MCPRequest, as identity: BridgeIdentity, store: Store
    ) async -> Subject {
        // Enforced here as well as in the toolbox, because the toolbox's gate is what a
        // `tools/call` goes through and a process speaking raw MCP at the socket is not
        // obliged to.
        guard roles.contains(identity.role) else {
            return .refused(
                "Only the owner's own client, or the agent working in a workspace, can archive one."
            )
        }

        var arguments: [String: JSONValue] = [:]
        if case .object(let object)? = request.params { arguments = object }

        guard identity.role == .owner else {
            guard let workspaceID = identity.workspaceID, let sessionID = identity.sessionID else {
                return .refused(BridgeWorkspaceScope.refusal(tool: "workspace_archive", doing: "archives"))
            }
            if arguments.isEmpty {
                do {
                    guard let own = try await store.workspace(id: workspaceID) else {
                        return .refused("That workspace is no longer in Bloom, so there is nothing to archive.")
                    }
                    return .found(own, sessionID)
                } catch {
                    return .refused("Bloom could not read this workspace. Nothing was archived; try again shortly.")
                }
            }
            return await started(request, arguments: arguments, by: workspaceID, store: store)
        }

        guard Set(arguments.keys) == ["id"],
              let rawID = request.stringParam("id")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawID.isEmpty else {
            return .refused("Pass only 'id', using the exact workspace id from workspace_list. There is no force option.")
        }
        do {
            guard let found = try await store.workspace(id: WorkspaceID(rawID)) else {
                return .refused("No workspace has that id. Call workspace_list and use the id it reports.")
            }
            return .found(found, nil)
        } catch {
            return .refused("Bloom could not read this workspace. Nothing was archived; try again shortly.")
        }
    }

    /// A workspace agent naming a workspace, which it may only do for one it started.
    ///
    /// Answered at once rather than booked, with no turn excused, because the caller is not
    /// standing in that worktree. See the head of this type.
    private func started(
        _ request: MCPRequest, arguments: [String: JSONValue], by caller: WorkspaceID, store: Store
    ) async -> Subject {
        guard Set(arguments.keys) == ["id"],
              let rawID = request.stringParam("id")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawID.isEmpty else {
            return .refused("""
                workspace_archive takes nothing, to archive the workspace you are in, or only 'id', \
                with the id workspace_start reported for a workspace you started. There is no force \
                option and no way to delete the branch.
                """)
        }
        let notStarted = """
            workspace_archive can archive the workspace you are in, or one you started with \
            workspace_start, and '\(rawID)' is not one you started. Pass the id workspace_start \
            reported, or leave 'id' out to archive your own. Ask the owner about any other workspace.
            """
        do {
            guard let found = try await store.workspace(id: WorkspaceID(rawID)) else {
                return .refused(notStarted)
            }
            if found.id == caller {
                return .refused("""
                    That is the workspace you are in. Leave 'id' out to archive your own, which \
                    Bloom does once your turn has ended.
                    """)
            }
            guard found.origin.parentWorkspaceID == caller else { return .refused(notStarted) }
            return .found(found, nil)
        } catch {
            return .refused("Bloom could not read that workspace. Nothing was archived; try again shortly.")
        }
    }
}
