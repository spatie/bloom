import Foundation

// The typed ids for messages between workspaces, beside `Identifier.swift` rather than in it.
// That file is also being moved into a package on the server runtime branch, and every id
// appended to it on main was a conflict there copied across by hand. The protocol, and the
// reasons every id is a type of its own, are still in `Identifier.swift`.

/// A message one workspace's agent sent another through `workspace_say`. See `WorkspaceMessage`.
public struct WorkspaceMessageID: Identifier {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// A chat's standing request to be told once when another workspace's turn comes to rest. See
/// `WorkspaceDoneWatch`.
public struct WorkspaceDoneWatchID: Identifier {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}
