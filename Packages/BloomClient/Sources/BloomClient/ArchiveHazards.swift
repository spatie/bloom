import Foundation

/// What the app knows about a workspace that a git process cannot.
///
/// Deliberately not fields on `WorkspaceSafetyReport`. That type is computed by running git, and
/// every field on it is something git answered; none of these is. An agent mid turn is a process
/// the app is holding a handle to, and the pull request's state came from `gh` minutes ago and is
/// cached above the core. Putting them on the report would mean a report that is wrong until
/// whoever built it remembers to correct it, which is the kind of half-filled safety check that
/// decides whether work gets destroyed.
public struct ArchiveHazards: Codable, Sendable, Hashable {
    /// An agent is mid turn in this workspace, right now.
    public var isAgentRunning: Bool
    /// GitHub says this branch's pull request was merged.
    ///
    /// Only ever `true` because GitHub actually said so, never inferred from its silence. The
    /// state it reflects is one-way: a pull request that has merged stays merged, so a cached
    /// answer can only ever be stale in the harmless direction, which is why the app is willing
    /// to read it from whichever surface asked last rather than blocking an archive on a network
    /// call.
    public var isPullRequestMerged: Bool
    /// Whether this archive will delete the branch as well as the worktree.
    public var isDeletingBranch: Bool

    public init(
        isAgentRunning: Bool = false,
        isPullRequestMerged: Bool = false,
        isDeletingBranch: Bool = false
    ) {
        self.isAgentRunning = isAgentRunning
        self.isPullRequestMerged = isPullRequestMerged
        self.isDeletingBranch = isDeletingBranch
    }

    /// The losses that are not git's to report.
    public var liveLosses: [String] {
        isAgentRunning
            ? ["the turn an agent is running in this workspace right now, which is not in git yet"]
            : []
    }
}
