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
/// The database column stays nullable: NULL is how SQLite says "the owner made this", and there is
/// no second column to disagree with it. This type is the one that refuses to be vague, and
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
    /// - Parameter spawnToolUseID: the single tool call that asked. Recorded because a tool call
    ///   is retried by the model, by the transport and by a user pressing the button again, and a
    ///   spawn with no way to recognise a repeat of itself cuts a second worktree every time.
    case agent(parentWorkspaceID: String, spawnToolUseID: String)

    /// The two columns, for the writer.
    public var parentWorkspaceID: String? {
        switch self {
        case .user: nil
        case .agent(let parent, _): parent
        }
    }

    public var spawnToolUseID: String? {
        switch self {
        case .user: nil
        case .agent(_, let toolUse): toolUse
        }
    }

    /// Whether an agent is answerable for this workspace at all. The one question the bridge asks
    /// before it will let anything through.
    public var isAgentSpawned: Bool { parentWorkspaceID != nil }

    /// Reads the two columns back.
    ///
    /// A row carrying a parent and no tool use, or the other way round, is not half an agent
    /// spawn: it is a row written by a version of Bloom that did not know about one of the two, or
    /// by hand. It reads as the owner's, which fails safe, because the only thing parentage grants
    /// is an agent's permission to reach into the workspace, and a record nobody can vouch for
    /// should grant nothing.
    public init(parentWorkspaceID: String?, spawnToolUseID: String?) {
        guard let parentWorkspaceID, !parentWorkspaceID.isEmpty,
              let spawnToolUseID, !spawnToolUseID.isEmpty else {
            self = .user
            return
        }
        self = .agent(parentWorkspaceID: parentWorkspaceID, spawnToolUseID: spawnToolUseID)
    }
}
