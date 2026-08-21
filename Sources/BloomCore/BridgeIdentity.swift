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
public struct BridgeIdentity: Sendable, Hashable {
    public let sessionID: SessionID
    public let workspaceID: WorkspaceID
    public let role: BridgeRole

    public init(sessionID: SessionID, workspaceID: WorkspaceID, role: BridgeRole) {
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.role = role
    }
}
