import Foundation

/// An identifier that knows what it identifies.
///
/// Every id in Bloom used to be a bare `String`, so `store.update(workspaceID: session.id)`
/// compiled, ran, and quietly updated nothing. Every one of those mistakes is a lookup that
/// returns nil or a write that lands on no row, which is the worst failure this app has: no
/// crash, no log line, just a workspace that did not archive or a chat whose title never
/// changed. The four ids that flow together are `RepoID`, `WorkspaceID`, `SessionID` and
/// `TerminalTabID`, and they all used to be the same type.
///
/// Distinct structs rather than one `ID<Entity>` phantom generic. The generic is less code, but
/// this protocol already reduces each declaration to a single line, so there was little left to
/// win, and two things to lose: a diagnostic that says `WorkspaceID` where the reader is already
/// thinking "workspace", and the room to hang something on one id without hanging it on all of
/// them.
///
/// `RawRepresentable` is not decoration. The stdlib ships `Codable` for anything
/// `RawRepresentable` whose `RawValue` is `String`, and it uses a single value container, so a
/// conforming type encodes as a bare JSON string and decodes from one. That is what keeps every
/// row and payload already on disk readable: see `IdentifierTests`, which pins it, because it is
/// a conformance inherited from another module and nothing here would notice it going away.
///
/// `CustomStringConvertible` is load bearing for a subtler reason. `CenterTabStore` and
/// `PromptAttachmentStore` build their user defaults keys by interpolating an id into a string.
/// Without `description`, `"tabs.\(id)"` becomes `tabs.WorkspaceID(rawValue: "abc")`, every key
/// changes, and every tab and attachment the owner had open is silently orphaned. With it the key
/// is byte for byte what it was.
public protocol Identifier: Hashable, Sendable, Codable, RawRepresentable,
                            CustomStringConvertible, Comparable
where RawValue == String {
    init(_ rawValue: String)
}

extension Identifier {
    public init(rawValue: String) { self.init(rawValue) }

    public var description: String { rawValue }

    /// A fresh identifier, in the one format this app has ever written: a lowercased UUID.
    public static func new() -> Self { Self(newID()) }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A project in the sidebar. Also `permission_grants.repo_id`, which is why a grant made for one
/// project cannot be read back for another.
public struct RepoID: Identifier {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// A worktree on disk. The id outlives the worktree: an archived workspace keeps its row, and the
/// row is what a restore reads.
public struct WorkspaceID: Identifier {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// One chat inside a workspace. Not the agent's own session id, which is a different value with a
/// different lifetime: see `Session.agentSessionID`.
public struct SessionID: Identifier {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// One terminal tab inside a workspace. Doubles as the tmux window name, so it is written into a
/// shell command and has to stay something a shell will accept.
public struct TerminalTabID: Identifier {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// A review note left on a line of a diff.
public struct ReviewCommentID: Identifier {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// A message somebody has asked for that has not gone to the agent yet. See `Delivery`.
public struct DeliveryID: Identifier {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// A standing "yes" to a tool the agent asked about, remembered per project.
public struct PermissionGrantID: Identifier {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}
