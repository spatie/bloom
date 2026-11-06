import Foundation

/// What GitLab reads can share: one read in flight per workspace, the last answer for a caller
/// that allows one, a short-lived cache of a finished pipeline's jobs, and each
/// directory's GitLab remote until its git config is written.
actor GitLabReads {
    static let shared = GitLabReads()
    /// These can be reused briefly, but a retry may start and finish without a poll seeing it.
    private static let finishedPipelines: Set<String> = ["success", "failed", "canceled", "skipped"]
    private static let finishedJobLifetime = Duration.seconds(30)

    private var snapshots: [String: (snapshot: GitLab.Snapshot?, at: ContinuousClock.Instant)] = [:]
    private var flights: [String: Task<GitLab.Snapshot?, Error>] = [:]
    private var finishedJobs: [String: (status: String, runs: [CheckRun], at: ContinuousClock.Instant)] = [:]
    private var remotes: [String: (configWritten: Date?, remote: GitLabRemote?)] = [:]

    func invalidateRemotes() { remotes.removeAll() }

    func snapshot(
        for worktree: String, maxAge: Duration,
        read: @escaping @Sendable () async throws -> GitLab.Snapshot?
    ) async throws -> GitLab.Snapshot? {
        if maxAge > .zero, let entry = snapshots[worktree], entry.at.duration(to: .now) <= maxAge {
            return entry.snapshot
        }
        if let flight = flights[worktree] { return try await flight.value }
        let flight = Task { try await read() }
        flights[worktree] = flight
        defer { flights[worktree] = nil }
        let snapshot = try await flight.value
        snapshots[worktree] = (snapshot, .now)
        return snapshot
    }

    /// The jobs read recently while the pipeline had this same final status.
    func jobs(of pipeline: String, status: String?, now: ContinuousClock.Instant = .now) -> [CheckRun]? {
        guard let status, let entry = finishedJobs[pipeline], entry.status == status,
              entry.at.duration(to: now) < Self.finishedJobLifetime else { return nil }
        return entry.runs
    }

    func remember(_ runs: [CheckRun], of pipeline: String, status: String?, now: ContinuousClock.Instant = .now) {
        guard let status, Self.finishedPipelines.contains(status) else {
            finishedJobs[pipeline] = nil
            return
        }
        // A retry can start and finish between polls, leaving the same final pipeline status.
        finishedJobs[pipeline] = (status, runs, now)
    }

    func remote(in directory: String, configWritten: Date?) -> GitLabRemote?? {
        guard let entry = remotes[directory], entry.configWritten == configWritten else { return nil }
        return .some(entry.remote)
    }

    func store(_ remote: GitLabRemote?, in directory: String, configWritten: Date?) {
        remotes[directory] = (configWritten, remote)
    }
}
