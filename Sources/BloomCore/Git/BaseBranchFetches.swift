import Foundation

/// The fetch that brings a base branch up to date, shared between whoever asks for it at once.
///
/// **The report this exists for.** "When you start a new session the default is main, which makes
/// sense, but there is no option for origin/main, so I often have outdated local main branches
/// that get used." The report was right, and it was not a missing option: `WorkspaceManager.cut` handed
/// the bare word `main` to `git worktree add`, which is the local branch, which Bloom never moves.
/// Continuing a merged workspace had fetched first all along; starting one never had.
///
/// Fetching on Create alone would have fixed it and made every Create wait on the network, for up
/// to `Git.fetch`'s twenty seconds on a remote that is not answering. So the create window starts
/// the fetch the moment it knows the base, while the task is still being written, and the cut
/// takes that answer rather than asking again when it is recent enough. That is the whole of the
/// sharing: a fetch already running is joined, and a fetch that worked within `recent` is trusted.
///
/// A fetch that failed is never remembered. Being offline a minute ago says nothing about now, and
/// the fallback it would have led to is `Git.baseRevision`'s to choose anyway.
///
/// Continuing after a merge passes no age, so it never trusts an earlier answer: the merge it is
/// continuing from is exactly what an earlier fetch would not have seen. It can still join a fetch
/// that is running, which is keyed on the worktree it runs in, and nothing but a continuation
/// fetches in a workspace's own worktree.
public actor BaseBranchFetches {
    public static let shared = BaseBranchFetches()

    /// How old a successful fetch may be for a new branch to be cut from what it brought. Long
    /// enough to cover writing a task in the create window, short enough that a window left open
    /// over lunch fetches again.
    public static let recent: Duration = .seconds(120)

    typealias Fetch = @Sendable (_ branch: String, _ directory: String) async -> Bool

    private struct Key: Hashable {
        let directory: String
        let branch: String
    }

    private let fetch: Fetch
    private let now: @Sendable () -> ContinuousClock.Instant
    private var inFlight: [Key: Task<Bool, Never>] = [:]
    private var succeededAt: [Key: ContinuousClock.Instant] = [:]

    init(
        fetch: @escaping Fetch = { await Git.fetch($0, in: $1) },
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.fetch = fetch
        self.now = now
    }

    /// Whether `origin/<branch>` is as the server has it, fetching only when nobody already has.
    ///
    /// - Parameter age: how old a remembered success may be and still count. Nil always fetches,
    ///   unless a fetch for the same branch in the same directory is already running.
    ///
    /// The task is detached for the reason `BaselineCache` gives: `Task {}` would inherit this
    /// actor. It also means a caller that is cancelled, which is the create window changing its
    /// base, leaves the fetch running for whoever asks next.
    public func refresh(
        _ branch: String, in directory: String, acceptingWithin age: Duration? = nil
    ) async -> Bool {
        let key = Key(directory: directory, branch: branch)
        if let age, let at = succeededAt[key], now() - at <= age { return true }
        // Nothing is awaited between the read and the write, so two callers cannot both start one.
        if let running = inFlight[key] {
            joined += 1
            return await running.value
        }

        let fetch = self.fetch
        let task = Task.detached(priority: Task.currentPriority) { await fetch(branch, directory) }
        inFlight[key] = task
        defer { inFlight[key] = nil }

        let fetched = await task.value
        if fetched { succeededAt[key] = now() }
        return fetched
    }

    /// Read by the suite. A flight that outlives its fetch is a key that can never fetch again.
    var flights: Int { inFlight.count }

    /// Read by the suite, which has to know a second caller is waiting before it lets a fetch end.
    private(set) var joined = 0
}
