import Foundation

/// One session row, reduced to the three columns that say whether an agent is working in it.
///
/// Read out of the store rather than built from a whole `Session`, because the question is asked
/// about every chat in the database at once and a `Session` carries a title, two token counts, a
/// cost and a context window that none of it needs.
public struct SessionActivity: Sendable, Hashable {
    public var sessionID: SessionID
    public var workspaceID: WorkspaceID
    public var state: SessionState

    public init(sessionID: SessionID, workspaceID: WorkspaceID, state: SessionState) {
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.state = state
    }
}

/// Whether an agent is working in a workspace, and whether one is blocked on a question.
///
/// # The bug this was written for
///
/// A workspace's sidebar row drew `circle.dotted`, the mark for a worktree with nothing in it,
/// while the centre column beside it streamed a turn: "Session started", a rate limit line and
/// three Bash calls, an agent plainly mid turn. The session row in the store said `running`
/// throughout. `WorkspaceStatus.resolve` was handed `isRunning: false` and correctly fell all the
/// way through to `.clean`, so the mark was right about the state it was given and the state was
/// wrong.
///
/// It was wrong because the app had **three** answers to "is an agent running here" and the
/// sidebar read the only one with nothing durable behind it:
///
/// - `WorkspaceModel.isRunning` walked the `TranscriptModel`s this launch happens to have built,
///   and `AppModel.runningWorkspaceIDs` mirrored that. It moved only when a turn started or
///   ended, from one call site, and nothing anywhere recomputed it. **A single missed edge was
///   therefore permanent for the rest of the turn**, and a turn in a chat no transcript had been
///   built for was invisible from the start.
/// - `WorkspaceModel.isRunning(_ session:)`, which the tab strip reads, already knew better: the
///   live transcript wherever one exists, the stored row otherwise.
/// - `WorkspaceLookup.isAgentRunning`, which Shortcuts read, took the stored row alone, and its
///   own comment says why that is the durable trace: the runner writes `Session.state` on every
///   move through `SessionLifecycle`, whether or not a window is watching.
///
/// So this is the middle answer, in one place, for all three to share. It is level triggered:
/// handed the store's rows and whatever the live transcripts say, it recomputes the whole answer,
/// so a missed edge heals on the next session write instead of lasting the turn.
///
/// # The precedence, and why it runs that way round
///
/// **A live transcript decides its own session, and a session with no transcript is decided by its
/// row.** The transcript is this process watching the agent's own output, so it hears a turn end
/// before the row is written; the row is the only thing that knows about a chat the window has
/// never opened. Neither can stand in for the other, and a plain union would keep a mark lit after
/// a turn ended, because the row lags the transcript by exactly the write that ends the turn.
public enum AgentTurns {
    /// What is being asked about. Both questions have the same shape and the same precedence, and
    /// writing them twice is how the pair drifts: `awaitingPermission` was added to the sidebar
    /// months after `running` and had to have every rule restated for it.
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        /// An agent has been handed something and has not finished with it.
        case running
        /// An agent has stopped and cannot go on until somebody answers.
        case awaitingPermission

        /// The stored state that means this, so the SQL that reads the rows is built from the same
        /// table the rule below is. See `Store.sessionActivity`.
        public var sessionState: SessionState {
            switch self {
            case .running: .running
            case .awaitingPermission: .waiting
            }
        }
    }

    /// What one live transcript says about its own session.
    ///
    /// It carries the workspace as well as the session, because a live turn in a chat whose row
    /// has not caught up yet is exactly the case this type exists for: there is no stored row to
    /// take the workspace from.
    public struct Live: Sendable, Hashable {
        public var sessionID: SessionID
        public var workspaceID: WorkspaceID
        public var isRunning: Bool
        public var isAwaitingPermission: Bool

        public init(
            sessionID: SessionID,
            workspaceID: WorkspaceID,
            isRunning: Bool,
            isAwaitingPermission: Bool
        ) {
            self.sessionID = sessionID
            self.workspaceID = workspaceID
            self.isRunning = isRunning
            self.isAwaitingPermission = isAwaitingPermission
        }

        /// This transcript's answer to one of the two questions.
        public func says(_ turn: Kind) -> Bool {
            switch turn {
            case .running: isRunning
            case .awaitingPermission: isAwaitingPermission
            }
        }
    }

    /// One session's answer: the live transcript where the window has built one, its row otherwise.
    public static func session(_ turn: Kind, state: SessionState, live: Live?) -> Bool {
        if let live { return live.says(turn) }
        return state == turn.sessionState
    }

    /// One workspace's answer, from the rows and the transcripts that workspace holds.
    ///
    /// Any session counts. A workspace with four chats runs four turns, and one of them finishing
    /// does not mean the workspace has stopped working.
    public static func workspace(_ turn: Kind, sessions: [Session], live: [Live]) -> Bool {
        let byID = index(live)
        return sessions.contains { session(turn, state: $0.state, live: byID[$0.id]) }
    }

    /// Every workspace with at least one session that counts.
    ///
    /// - Parameters:
    ///   - stored: the session rows the store says are mid turn or blocked. Rows in any other
    ///     state may be left out: a session absent from this list and absent from `live` counts
    ///     for nothing, which is the same answer including it would give.
    ///   - live: what every transcript this launch has built says about its own session.
    public static func workspaces(
        _ turn: Kind,
        stored: [SessionActivity],
        live: [Live]
    ) -> Set<WorkspaceID> {
        let byID = index(live)
        var found: Set<WorkspaceID> = []

        for row in stored where byID[row.sessionID] == nil {
            if row.state == turn.sessionState { found.insert(row.workspaceID) }
        }
        // Second, and unconditionally, so a turn that started before its row was written is
        // reported from the frame it started on rather than from the frame the runner got round
        // to saying so.
        for entry in live where entry.says(turn) {
            found.insert(entry.workspaceID)
        }

        return found
    }

    /// Keyed by session, last one wins, which cannot happen: a session has at most one transcript.
    private static func index(_ live: [Live]) -> [SessionID: Live] {
        Dictionary(live.map { ($0.sessionID, $0) }, uniquingKeysWith: { _, latest in latest })
    }
}
