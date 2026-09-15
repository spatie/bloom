import Foundation

/// A chat's request to be told, once, when the turn its `workspace_say` or `workspace_start` caused
/// in another workspace comes to rest.
///
/// ## Why it exists
///
/// Without it the only way back was to write "tell me when you are done" into the message and
/// trust the other agent to call `workspace_say` at the end. It often forgot, and when it did not
/// finish at all (it failed, or sat on a permission prompt nobody was looking at) it could not say
/// so, which left the calling agent waiting on an answer that was never coming. Inside one
/// workspace the same problem was solved by making the end of a subagent's turn an event Bloom
/// delivers; see `Crew.stoppedSentence`. This is that, one workspace further out.
///
/// ## Why a row rather than a flag in memory
///
/// The other turn can run for twenty minutes, and the owner can quit Bloom in the middle of it. A
/// promise kept in a transcript model would be forgotten on the next launch, so the watch is
/// written to `workspace_done_watches` when the call is made and spent there, with one `UPDATE ...
/// WHERE notified_at IS NULL`, when the notice goes. That statement is also what makes it at most
/// once: two endings arriving together both ask, and only one of them changes a row.
public struct WorkspaceDoneWatch: Identifiable, Sendable, Hashable {
    /// What the calling chat did to cause the turn it is waiting on.
    public enum Cause: Sendable, Hashable {
        /// A `workspace_say`. The state is the message's as it is now, read with the watch,
        /// because it decides whether a turn ending is about this message at all.
        case message(WorkspaceMessageID, state: WorkspaceMessage.State)
        /// A `workspace_start`. The first turn is the one the task was given in, so there is no
        /// earlier state to wait through.
        case start
    }

    public let id: WorkspaceDoneWatchID
    public let cause: Cause
    /// The chat that asked, which is where the notice goes.
    public let watcherSessionID: SessionID
    /// The workspace and chat being watched. `target.sessionID` nil means the workspace's own
    /// chats, not its subagents: a start whose first chat could not be read when the call answered.
    public let target: WorkspaceMessageEnd
    public let createdAt: Date
    public let notifiedAt: Date?

    public init(
        id: WorkspaceDoneWatchID = .new(),
        cause: Cause,
        watcherSessionID: SessionID,
        target: WorkspaceMessageEnd,
        createdAt: Date = Date(),
        notifiedAt: Date? = nil
    ) {
        self.id = id
        self.cause = cause
        self.watcherSessionID = watcherSessionID
        self.target = target
        self.createdAt = createdAt
        self.notifiedAt = notifiedAt
    }

    /// What to do with this watch now that a turn in the target workspace has ended this way.
    ///
    /// - Parameters:
    ///   - sessionID: the chat whose turn ended. Ignored for `.archived`, which is about the
    ///     whole workspace.
    ///   - isSubagentChat: whether that chat is a crew member rather than one of the workspace's
    ///     own chats. A subagent finishing is not the workspace finishing.
    public func verdict(
        on ending: WorkspaceTurnEnding, in sessionID: SessionID?, isSubagentChat: Bool
    ) -> WorkspaceDoneVerdict {
        guard notifiedAt == nil else { return .ignore }

        // A message the owner took back out is already covered by the cancelled notice, and a
        // second notice about a turn it never caused would contradict that one.
        if case .message(_, .cancelled) = cause { return .discard }

        if ending != .archived {
            if let watched = target.sessionID {
                guard watched == sessionID else { return .ignore }
            } else if isSubagentChat {
                return .ignore
            }
            // Still queued: the turn that ended is the one the message is waiting behind, and the
            // turn it will cause has not started.
            if case .message(_, .queued) = cause { return .ignore }
        }

        return .notify(WorkspaceDoneNotice.message(for: ending, watch: self))
    }

    /// The argument both tools take, and its description, said once so the two cannot drift.
    public static let argument = "notify_when_done"

    /// Whether a call asked for it. A string "true" is taken as well as a boolean, because a model
    /// writing arguments by hand passes either, and reading "true" as no would be a promise the
    /// caller believes it was given and was not.
    public static func isRequested(_ value: JSONValue?) -> Bool {
        switch value {
        case .bool(let flag)?: flag
        case .string(let text)?: text.trimmingCharacters(in: .whitespaces).lowercased() == "true"
        default: false
        }
    }

    /// Whether this was a message the other agent never read, which the archived notice says.
    var wasNeverRead: Bool {
        if case .message(_, .queued) = cause { return true }
        return false
    }
}

/// How a turn in a watched workspace came to rest, as the app observed it.
public enum WorkspaceTurnEnding: Sendable, Hashable {
    /// The turn ended by itself and nothing queued started another. The agent's last message.
    case finished(lastMessage: String?)
    /// The owner pressed Stop.
    case stoppedByOwner
    /// The agent died, or the turn ended in an error.
    case failed(reason: String)
    /// Blocked on a permission prompt for this tool.
    case waitingOnPermission(tool: String)
    /// Blocked on a question it asked the owner.
    case waitingOnQuestion
    /// The workspace was archived.
    case archived

    /// A turn's own result. Here rather than in the transcript so the reading of a result that did
    /// not succeed is one a test can hold.
    public static func ofResult(_ result: AgentResult, stoppedByOwner: Bool) -> WorkspaceTurnEnding {
        if stoppedByOwner { return .stoppedByOwner }
        if result.succeeded { return .finished(lastMessage: result.summary) }
        let reason = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(reason: reason.isEmpty ? result.subtype : reason)
    }

    /// A question for the owner, or a permission prompt, which a caller elsewhere needs told apart
    /// only in the words: both mean the agent is blocked until a person answers.
    public static func ofAsk(_ ask: PermissionAsk) -> WorkspaceTurnEnding {
        ask.isQuestion ? .waitingOnQuestion : .waitingOnPermission(tool: ask.toolName)
    }
}

/// What Bloom does with one watch after one ending.
public enum WorkspaceDoneVerdict: Sendable, Equatable {
    /// Not this turn. The watch stays as it is.
    case ignore
    /// Spent with nothing said.
    case discard
    /// Spent, and this goes into the calling chat.
    case notify(CrewMessage)
}
