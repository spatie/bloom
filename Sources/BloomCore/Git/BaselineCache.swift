import Foundation

/// What `Git.baseline` remembers, so that asking the same question twice costs one process
/// instead of four.
///
/// # The measurement, including the half of it that did not work
///
/// The sidebar's diff stat refreshes every six seconds, and each refresh walks
/// `Git.changedFiles`, which opens with `baseline`. `baseline` is deliberately careful: it
/// resolves the local base, the remote-tracking base and, when they differ, asks which of the two
/// divergence points is further along. That is three or four `git` processes before the first
/// `diff` has run, and `changedFiles` then runs three more.
///
/// `IdleProbe` over seventeen of this machine's real worktrees, seven passes, median:
///
///     processes per worktree   6.12  ->  4.00
///     process time per pass    2864ms -> 2949ms
///
/// **So this cut a third of the processes and moved the CPU not at all.** The two calls it
/// removes are `merge-base` and a `rev-parse`, both of which only read the commit graph; the time
/// is in the three `diff` and `ls-files` calls that walk the worktree, and those still run. It is
/// kept because it is a strictly cheaper way to ask exactly the same question and every one of
/// those processes is also two reader threads and a merged environment, and because it costs
/// nothing to keep. It is not what fixed the battery menu. `DiffRefreshSchedule` is.
///
/// # Why a fingerprint rather than a time to live
///
/// A merge base is a pure function of the commit graph, and the only parts of that graph the
/// answer can depend on are the three refs `baseline` reads. So the cache is not keyed on age, it
/// is keyed on those refs: if `HEAD`, the base and the remote-tracking base all still point at the
/// same commits, the divergence point is the same commit too, and no amount of elapsed time can
/// make that false. A stale answer is impossible rather than unlikely.
///
/// One `git rev-parse --revs-only HEAD <base> refs/remotes/origin/<base>` is the whole check.
/// `--revs-only` prints a line per argument it could resolve and silently drops the rest, exiting
/// zero either way, so a ref that appears or vanishes changes the number of lines and therefore
/// the fingerprint. The joined lines are the key; which line was which never has to be worked out,
/// because any difference at all is a miss.
///
/// A miss now costs one process more than it used to. That is the right trade: a ref moves when an
/// agent commits or a fetch lands, which is a handful of times an hour, and the question is asked
/// every six seconds per workspace.
enum BaselineFingerprint {
    /// The refs whose position the merge base depends on, in the order they are asked for.
    ///
    /// `base` unqualified rather than `refs/heads/<base>`, because that is what `mergeBase` itself
    /// resolves and a base that is a tag or a bare sha has to be covered too: a tag that moves
    /// moves the answer with it.
    static func arguments(base: String, remote: String) -> [String] {
        ["rev-parse", "--revs-only", "HEAD", base, "refs/remotes/\(remote)/\(base)"]
    }

    /// The lines `rev-parse` printed, joined. Whitespace-trimmed per line so a trailing newline
    /// or a `\r` from a Windows-configured git cannot read as a different graph.
    ///
    /// An empty answer is nil rather than an empty fingerprint. `rev-parse` printing nothing means
    /// it could not resolve a single one of the three, which is a repository that is broken or
    /// gone, and remembering "the state where nothing resolves" would let two different broken
    /// worktrees share an entry.
    static func make(_ output: String) -> String? {
        let lines = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: " ")
    }
}

/// The store behind `BaselineFingerprint`, one entry per worktree and base branch.
///
/// An actor because `baseline` is called from the refresh loop, from the safety report and from
/// the review tab at once, and two of those racing on a dictionary is a crash rather than a stale
/// number.
///
/// Bounded, because a worktree is archived and a new one is created several times a day and an
/// unbounded dictionary keyed on paths is a leak with a slow fuse. `limit` is generous next to any
/// real sidebar; the eviction is least-recently-used and only runs when the limit is passed, so
/// the common case never sorts anything.
actor BaselineCache {
    static let shared = BaselineCache()

    static let limit = 256

    private struct Key: Hashable {
        let worktree: String
        let base: String
    }

    private struct Entry {
        let fingerprint: String
        let baseline: String
        var usedAt: UInt64
    }

    /// The flights in progress, keyed on the fingerprint as well, because a resolve that started
    /// before a ref moved is working out the merge base of a graph that no longer exists. Joining
    /// it would hand back an answer for the old graph, which is the squash-merge bug again.
    private struct Flight: Hashable {
        let key: Key
        let fingerprint: String
    }

    private var entries: [Key: Entry] = [:]
    private var inFlight: [Flight: Task<String, Error>] = [:]

    /// A counter rather than a clock, because `Date()` is not guaranteed to differ between two
    /// entries written in the same loop and an eviction that cannot order its candidates is one
    /// that throws away a different entry each run.
    private var clock: UInt64 = 0

    /// The remembered answer, if the three refs are where they were when it was worked out.
    func baseline(worktree: String, base: String, fingerprint: String) -> String? {
        let key = Key(worktree: worktree, base: base)
        guard var entry = entries[key], entry.fingerprint == fingerprint else { return nil }
        clock += 1
        entry.usedAt = clock
        entries[key] = entry
        return entry.baseline
    }

    func remember(worktree: String, base: String, fingerprint: String, baseline: String) {
        clock += 1
        entries[Key(worktree: worktree, base: base)] = Entry(
            fingerprint: fingerprint, baseline: baseline, usedAt: clock
        )
        guard entries.count > Self.limit else { return }
        let oldest = entries
            .sorted { $0.value.usedAt < $1.value.usedAt }
            .prefix(entries.count - Self.limit)
        for (key, _) in oldest { entries[key] = nil }
    }

    /// The remembered answer, or the one a caller that got here first is already working out.
    ///
    /// `changedFiles` and `branchCommits` both open with `baseline`, and they used to be ordered
    /// so the second was always a hit. Run together they are two misses on a cold cache, which is
    /// three extra processes on the workspace switch this coalescing exists to shorten.
    ///
    /// The task is detached rather than `Task {}`, which would inherit this actor and put the git
    /// calls' home executor on the cache.
    func baseline(
        worktree: String,
        base: String,
        fingerprint: String,
        resolve: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        if let remembered = baseline(worktree: worktree, base: base, fingerprint: fingerprint) {
            return remembered
        }

        let flight = Flight(key: Key(worktree: worktree, base: base), fingerprint: fingerprint)
        // Nothing is awaited between the read and the write, so two callers cannot both find it
        // empty and both start a resolve.
        if let running = inFlight[flight] { return try await running.value }

        let task = Task.detached(priority: Task.currentPriority) { try await resolve() }
        inFlight[flight] = task
        // Only the caller that started it clears it, and it clears it whether the resolve threw
        // or not: an entry left behind is a worktree that can never be asked about again.
        // Awaiting a task's value is not cancelled by the awaiting task, so this always runs.
        defer { inFlight[flight] = nil }

        let answer = try await task.value
        remember(worktree: worktree, base: base, fingerprint: fingerprint, baseline: answer)
        return answer
    }

    /// Read by the suite, which is what pins the bound above.
    var count: Int { entries.count }

    /// Read by the suite. A flight that outlives its resolve is a leak with no symptom.
    var flights: Int { inFlight.count }
}
