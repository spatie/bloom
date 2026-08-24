import Foundation

/// How many workspaces a caller may start, and how fast.
///
/// Three answers to one question, in one place, because they were in three and nothing said they
/// were related. The Create sheet is uncapped, a parent agent may have eight children running, and
/// the owner's own client may start six in a quarter of an hour. Read apart, those look like an
/// omission, a safety limit and a rate limit. Read together they are one rule with one variable in
/// it, which is **how much a workspace costs the caller to ask for**.
///
/// A workspace is a real git worktree, a real agent process and real spend. The sheet needs a
/// human gesture per workspace, so the cost of asking is already a person's attention and nothing
/// else has to stand in for it. A tool call costs nothing, and the caller is a model acting on an
/// instruction it interpreted, so something has to. What that something is depends on who the
/// caller is, and `WorkspaceOrigin` is the only thing that knows.
///
/// The two brakes are shaped differently on purpose, and it is not a ceiling versus a window by
/// accident. A parent's children are work it is waiting on, so what matters is how many are alive
/// at once and a ceiling is right. The owner is a person whose workspaces accumulate over weeks,
/// so a ceiling would refuse the eleventh workspace of a busy fortnight, which is ordinary use
/// rather than a runaway. What is not ordinary is the rate, so the brake is on how fast.
///
/// Neither number is a safety limit. Six worktrees and six agents is already real money, and the
/// point of both is that somebody notices at six or at eight instead of at forty.
public enum WorkspaceStartAllowance: Sendable, Equatable {
    /// No brake, because the asking is already the brake. The Create sheet, a `bloom://` link, the
    /// Services menu and a Shortcut: each of them is one deliberate gesture per workspace.
    case unlimited

    /// At most `limit` of this caller's workspaces running at once.
    ///
    /// Counted from the database rather than kept in memory, so it survives Bloom being reopened
    /// while the children are still running and so two calls racing cannot both see the same stale
    /// number. Archived ones do not count: the limit is on what is running.
    case running(limit: Int)

    /// At most `limit` started inside the last `window`.
    ///
    /// Counted from the database for the same two reasons, and for a third: a restart does not
    /// hand out a fresh allowance.
    case rate(limit: Int, window: TimeInterval)

    /// How many a single agent may have running at once.
    ///
    /// Not a safety limit, a sanity one: an agent that misreads its own instructions can ask for
    /// workspaces in a loop. Eight is more than anyone has wanted and small enough that a runaway
    /// is noticed rather than discovered on the next bill.
    public static let maximumChildren = 8

    /// How many the owner's own client may start inside `ownerWindow`.
    ///
    /// The largest deliberate fan-out anybody has asked for in one sitting is a handful, and six
    /// leaves room above that. A loop, whose calls are seconds apart, hits it inside a minute,
    /// having cut six worktrees rather than forty.
    public static let maximumOwnerStarts = 6

    /// Fifteen minutes: long enough that no loop can outrun it, and short enough that a person who
    /// genuinely wanted a seventh is inconvenienced rather than blocked.
    public static let ownerWindow: TimeInterval = 15 * 60

    /// The brake that applies to a workspace asked for this way.
    ///
    /// The one switch, and the reason `WorkspaceOrigin` is the seam rather than a parallel notion
    /// of who is calling. Adding a fourth kind of caller makes this stop compiling, which is the
    /// point: a new door with no answer to "how many" is the gap `workspace_start` shipped with.
    public static func of(_ origin: WorkspaceOrigin) -> WorkspaceStartAllowance {
        switch origin {
        case .user: .unlimited
        case .agent: .running(limit: maximumChildren)
        case .ownerClient: .rate(limit: maximumOwnerStarts, window: ownerWindow)
        }
    }

    /// Whether `count` is already at the limit, where `count` was gathered the way this case says
    /// to gather it: running workspaces for `.running`, ones started inside the window for
    /// `.rate`.
    public func isExceeded(by count: Int) -> Bool {
        switch self {
        case .unlimited: false
        case .running(let limit): count >= limit
        case .rate(let limit, _): count >= limit
        }
    }

    /// What a caller that has hit it is told, or nil when it has not.
    ///
    /// Both sentences are written against one particular misreading. A model that has just been
    /// refused reads any mention of a limit as a condition to wait out, and a model that waits and
    /// retries has turned a brake into a slower loop. So each says plainly what would clear it and
    /// what to do meanwhile, and neither names a path, a command, or a limit the owner could
    /// raise, because there is nothing to raise from here.
    public func refusal(count: Int) -> String? {
        guard isExceeded(by: count) else { return nil }

        switch self {
        case .unlimited:
            return nil

        case .running:
            return "You already have \(count) workspaces running, which is Bloom's limit. "
                + "Wait for some to be reviewed and archived before starting more."

        case .rate(_, let window):
            let minutes = Int(window / 60)
            return """
                Bloom has already started \(count) workspaces for you in the last \(minutes) \
                minutes, which is as many as it will start from a client outside the app. Each one \
                is a real git worktree, a real agent process and real spend, and this many in this \
                short a time is what a misread instruction looks like rather than a plan. Calling \
                again will be refused for the same reason, and nothing you can do here shortens \
                the \(minutes) minutes, so do not retry and do not wait for it. Tell the owner what \
                you have already started and what is left over, and leave the rest to them: \
                Bloom's own window starts workspaces with no limit, one deliberate press at a time.
                """
        }
    }
}
