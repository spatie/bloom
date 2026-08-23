import Foundation

/// Which side of the family a caller is on, and therefore which tools it can even see.
///
/// Read from the database at mint time, never from the shim's environment: `whoami` is harmless
/// either way, but the tools that follow are not, and a role a caller could state is a role a
/// caller could raise. A workspace with a parent is a child, and that is the whole test. There is
/// no depth counter because the limit on nesting is one, so "has a parent" IS the depth, and a
/// number kept beside it is a number that can drift out of step with the parent it describes.
public enum BridgeRole: String, Sendable, Hashable, Codable, CaseIterable {
    /// A workspace the owner created. It may spawn children.
    case parent
    /// A workspace an agent created. It reports and nothing else.
    case child
    /// The owner, through a client of their own, sitting in no workspace at all.
    ///
    /// The third role, and the odd one, because the other two are derived from a workspace row and
    /// this one is derived from nothing: there is no session, no worktree and no project behind
    /// it. It is the person, reaching Bloom from a `claude` they started themselves in a terminal
    /// anywhere on the machine, with Bloom registered in their own MCP configuration.
    ///
    /// **It is not a child.** A child is deliberately penned in, because a child is an agent that
    /// another agent asked for and nobody weighed. **It is not a parent either**, because a parent
    /// is a workspace: every tool a parent has is implicitly scoped to the worktree it is sitting
    /// in, and this caller is sitting in none, so nothing can be implied on its behalf and every
    /// project has to be named out loud.
    ///
    /// What it may do is what the owner may do from the sidebar and no more: see the projects,
    /// register an existing repository as one, and start a workspace in one of them. What it may
    /// not do is anything scoped to a workspace, because it has none to be scoped to, and anything
    /// that destroys work, because the whole reason Bloom asks before archiving is that the answer
    /// is sometimes no and there is nobody on this connection to ask.
    case owner

    public init(origin: WorkspaceOrigin) {
        self = origin.isAgentSpawned ? .child : .parent
    }
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
