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

/// One metric in the usage panel: a provider and a window or balance, as `provider/key`, e.g.
/// `claudeCode/five_hour` or `codex/weekly`. Stored in the panel's layout, so the text is a key
/// that has to stay what it was the day somebody starred it.
public struct UsageMetricID: Identifier {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// A project in the sidebar. Also `permission_grants.repo_id`, which is why a grant made for one
/// project cannot be read back for another.
public struct RepoID: Identifier {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// A named, isolated CLI sign-in managed by Bloom.
public struct AgentAccountProfileID: Identifier {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// A worktree on disk. The id outlives the worktree: an archived workspace keeps its row, and the
/// row is what a restore reads.
public struct WorkspaceID: Identifier {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// One dated or ordered group in Home's mixed workspace and conversation list.
public struct HomeMixedGroupID: Identifier {
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

/// A pane in a project-free conversation. Its first pane also names the tab containing it.
public struct ConversationPaneID: Identifier {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// A review note left on a line of a diff.
public struct ReviewCommentID: Identifier {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// One of the owner's own quick prompts, the text of which goes into the composer's draft.
public struct QuickPromptID: Identifier {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// One of the owner's saved model presets, the named sets the composer's model menu lists.
public struct ModelPresetID: Identifier {
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

/// One run of the Agent tool inside a session, as the CLI numbers it.
///
/// The raw value is `task_id` off `system/task_started`, and it is the CLI's, not Bloom's: it is
/// the only handle that all four lines about a subagent agree on, and it is what names that
/// subagent's own transcript on disk. So `new()` is never called for one. It is also not stored,
/// because a subagent lives for seconds and nothing outlives the turn that spawned it.
public struct SubagentID: Identifier {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// A message sent from one workspace to another through `workspace_say`.
public struct WorkspaceMessageID: Identifier {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// A request to be told when another workspace's turn finishes.
public struct WorkspaceDoneWatchID: Identifier {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// One message in a Mailpit mailbox, as Mailpit names it.
///
/// Not a Bloom row: Mailpit assigns it, Bloom never makes one, and it means nothing once the
/// mailbox is cleared. It has a type anyway, because the API and the selected message both use it;
/// a bare string could be mistaken for a workspace id or an attachment part.
public struct MailpitMessageID: Identifier {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}
