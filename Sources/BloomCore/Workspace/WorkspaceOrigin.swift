import Foundation

/// Who asked for a workspace to exist.
///
/// A workspace an agent asked for is an ordinary Bloom workspace with an ordinary agent in it.
/// Nothing about it is lesser, nothing about it belongs to a turn, and it outlives whatever asked
/// for it. The only thing this records is who asked, because that is what decides which agent may
/// later message it or archive it.
///
/// A sum type rather than a pair of optional fields, because the two cases have different
/// obligations and an optional cannot hold a caller to either of them. A workspace the owner made
/// has no parent and never will; a workspace an agent asked for has one, and the whole of the
/// bridge that lets an agent reach the workspace it started rests on that record being there. Two
/// nullable fields would let `.agent` be half filled in, and the half that goes missing is the one
/// nobody notices until an agent is refused permission over a workspace it created itself.
///
/// So `.agent` will not compile without both ids and `.user` cannot smuggle either of them in.
///
/// The third case, `.ownerClient`, is the owner asking through a tool rather than through a hand.
/// It is on the owner's side of the only line this type draws, `isAgentSpawned`, and it exists
/// because a tool call can be retried and can arrive in a loop, neither of which a press of a
/// button in the sheet can do.
///
/// The database columns stay nullable: NULL in both is how SQLite says "the owner made this by
/// hand". This type is the one that refuses to be vague, and
/// `init(parentWorkspaceID:spawnToolUseID:)` is the single place a row is read back into it.
public enum WorkspaceOrigin: Sendable, Equatable, Hashable, Codable {
    /// The owner, through the sheet, a `bloom://` link, the Services menu or a Shortcut.
    case user

    /// An agent running in another workspace asked for this one.
    ///
    /// - Parameter parentWorkspaceID: the workspace the agent that asked for this one is running
    ///   in. The parent WORKSPACE and deliberately not the parent session: a worktree holds many
    ///   sessions over its life, they are archived, replaced and resumed, and the question this
    ///   record has to answer months later is "did the caller create this", where the caller is an
    ///   agent identified by the worktree it is running in. Keyed on a session id, the answer would
    ///   turn to no the moment the parent's chat was replaced, and an agent would be refused
    ///   permission over a workspace it genuinely made.
    /// - Parameter spawnToolUseID: a name for the single tool call that asked, which a repeat of
    ///   that call produces again. Recorded because a tool call is retried by the model and by the
    ///   transport, and a spawn with no way to recognise a repeat of itself cuts a second worktree
    ///   every time.
    ///
    ///   **Not the model's own `tool_use` id.** MCP does not carry it to the server, so it is not
    ///   available to record; a fresh UUID was recorded instead for a while, which meant two
    ///   identical calls produced two ids and the dedup this field exists for could not happen.
    ///   It is a digest of the call, which repeats exactly when the call repeats. See
    ///   `AgentWorkspaceOrder.spawnID`.
    case agent(parentWorkspaceID: WorkspaceID, spawnToolUseID: String)

    /// The owner, through `workspace_start` on a client of their own, sitting in no workspace.
    ///
    /// The owner asked for it, so it is not `.agent`: nothing about it is penned in, it may start
    /// children of its own, and `isAgentSpawned` is false exactly as it is for `.user`. What makes
    /// it its own case is that a tool asked rather than a hand, and two facts follow from that
    /// which the sheet never has to answer.
    ///
    /// A tool call is retried, so the call that asked has to be nameable, which is the associated
    /// value. `.user` cannot carry one and should not: the sheet's second press is a second ask.
    ///
    /// And a tool call takes no gesture, so the rate at which these arrive is worth counting,
    /// which a mixture of these and sheet-made rows could not be counted from. See
    /// `WorkspaceStartAllowance`.
    ///
    /// It costs no column. A row with a spawn id and no parent used to read back as `.user`,
    /// which was the safest reading while nothing could write one; this is what writes one.
    case ownerClient(spawnToolUseID: String)

    /// The two columns, for the writer.
    public var parentWorkspaceID: WorkspaceID? {
        switch self {
        case .user, .ownerClient: nil
        case .agent(let parent, _): parent
        }
    }

    public var spawnToolUseID: String? {
        switch self {
        case .user: nil
        case .agent(_, let toolUse): toolUse
        case .ownerClient(let toolUse): toolUse
        }
    }

    /// Whether an agent is answerable for this workspace at all. The one question the bridge asks
    /// before it will let anything through.
    public var isAgentSpawned: Bool { parentWorkspaceID != nil }

    /// Whether the owner's own client asked for this one through `workspace_start`.
    ///
    /// What the rolling window counts. Separate from `isAgentSpawned` because these are the
    /// owner's workspaces in every way that matters to the role model, and only the rate they
    /// arrive at is anybody's business.
    public var isOwnerClient: Bool {
        if case .ownerClient = self { return true }
        return false
    }

    /// Reads the two columns back.
    public init(parentWorkspaceID: String?, spawnToolUseID: String?) {
        let parent = (parentWorkspaceID?.isEmpty ?? true) ? nil : parentWorkspaceID
        let spawn = (spawnToolUseID?.isEmpty ?? true) ? nil : spawnToolUseID

        switch (parent, spawn) {
        case let (parent?, spawn?):
            self = .agent(parentWorkspaceID: WorkspaceID(parent), spawnToolUseID: spawn)
        case let (nil, spawn?):
            self = .ownerClient(spawnToolUseID: spawn)
        // A parent with no tool call is not half an agent spawn: it is a row written by a version
        // of Bloom that did not know about the second column, or by hand. It reads as the owner's,
        // which fails safe, because the only thing parentage grants is an agent's permission to
        // reach into the workspace, and a record nobody can vouch for should grant nothing.
        case (_, nil):
            self = .user
        }
    }
}
