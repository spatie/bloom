import Foundation

/// Whether a caller is standing in a workspace, and therefore which tools it can even see.
///
/// Read from the token at mint time, never from the shim's environment: a role a caller could
/// state is a role a caller could raise.
///
/// ## Why there are two and not three
///
/// There used to be a third, `child`, for a workspace another agent had started, and it could call
/// `whoami` and `workspace_say` and nothing else. The reasoning was that nobody had weighed that
/// agent, so it should report and do no more. In use it cost more than it protected. A child could
/// not archive or rename itself when its starter asked it to, could not read the chat it was
/// answering, and could not open a terminal in its own worktree, while the owner's own
/// registration of the bridge, which Claude Code applies to every session on the machine, handed
/// it the owner's tools regardless. The pen was not holding and the work was paying for it.
///
/// What actually stops a runaway agent is still here, and none of it needed a role. A workspace an
/// agent started may not start more (`WorkspaceStartTool`, off `WorkspaceOrigin.isAgentSpawned`).
/// Anything that destroys work is asked about (`BridgeToolApproval`). Archiving runs the safety
/// check with nothing forced (`WorkspaceArchiveSafety`). Messages are throttled
/// (`WorkspaceSayThrottle`). And the owner's token is refused to a shim running inside a
/// worktree, so the owner's tools do not leak into a workspace (`BridgeOwnerPlacement`).
public enum BridgeRole: String, Sendable, Hashable, Codable, CaseIterable {
    /// An agent running in a workspace, however that workspace came to exist.
    ///
    /// Everything it calls is scoped to its own workspace unless the tool says otherwise, and the
    /// few that reach further (`workspace_say`, the reads, and archiving or renaming a workspace it
    /// started) say so in their own heads.
    case workspace
    /// The owner, through a client of their own, sitting in no workspace at all.
    ///
    /// Derived from nothing, where the other role is derived from a workspace row: there is no
    /// session, no worktree and no project behind it. It is the person, reaching Bloom from a
    /// `claude` they started themselves in a terminal, with Bloom registered in their own MCP
    /// configuration, or Ask Bloom inside the app.
    ///
    /// **It is not a workspace**, because every tool a workspace agent has is implicitly scoped to
    /// the worktree it is sitting in, and this caller is sitting in none, so nothing can be implied
    /// on its behalf and every project and workspace has to be named out loud.
    ///
    /// What it may not do is anything scoped to a workspace, because it has none to be scoped to,
    /// and anything that discards unprotected work. `workspace_archive` retains the branch and
    /// refuses anything the normal archive lifecycle would need the owner to confirm.
    case owner
}

/// What a token stands for.
///
/// The session as well as the workspace, because the two answer different questions and only one
/// of them is deliverable. A worktree holds several chats at once and each has its own backend and
/// its own conversation, so anything addressed to a workspace is addressed to nobody in
/// particular. The workspace is what parentage is recorded against, and is what survives a chat
/// being replaced.
///
/// Both are optional, and only for `.owner`. That role has no session and no workspace by
/// definition, and the alternative was a sentinel id pointing at a row that does not exist, which
/// every reader would have to know to distrust. An optional is checkable, and the two places that
/// need one (`whoami` and `workspace_start`) check it and say something true when it is absent.
public struct BridgeIdentity: Sendable, Hashable {
    public let sessionID: SessionID?
    public let workspaceID: WorkspaceID?
    public let role: BridgeRole

    public init(sessionID: SessionID, workspaceID: WorkspaceID, role: BridgeRole) {
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.role = role
    }

    private init(role: BridgeRole) {
        self.sessionID = nil
        self.workspaceID = nil
        self.role = role
    }

    /// The owner's own client. One identity for the whole machine, because there is only one owner
    /// and nothing about which terminal they typed in is worth recording.
    public static let owner = BridgeIdentity(role: .owner)
}
