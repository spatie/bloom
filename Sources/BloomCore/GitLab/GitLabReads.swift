import Foundation

/// What GitLab reads can share: one read in flight per workspace, the last answer for a caller
/// that allows one, the jobs of a pipeline that has finished, which cannot change, and each
/// directory's GitLab remote until its git config is written.
actor GitLabReads {
    static let shared = GitLabReads()
    /// Final until somebody retries a job, which moves the pipeline back to running and so misses.
    private static let finishedPipelines: Set<String> = ["success", "failed", "canceled", "skipped"]

    private var snapshots: [String: (snapshot: GitLab.Snapshot?, at: ContinuousClock.Instant)] = [:]
    private var flights: [String: Task<GitLab.Snapshot?, Error>] = [:]
    private var finishedJobs: [String: (status: String, runs: [CheckRun])] = [:]
    private var remotes: [String: (configWritten: Date?, remote: GitLabRemote?)] = [:]

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

    /// The jobs read when the pipeline last had this same final status.
    func jobs(of pipeline: String, status: String?) -> [CheckRun]? {
        guard let status, let entry = finishedJobs[pipeline], entry.status == status else { return nil }
        return entry.runs
    }

    func remember(_ runs: [CheckRun], of pipeline: String, status: String?) {
        guard let status, Self.finishedPipelines.contains(status) else {
            finishedJobs[pipeline] = nil
            return
        }
        finishedJobs[pipeline] = (status, runs)
    }

    func remote(in directory: String, configWritten: Date?) -> GitLabRemote?? {
        guard let entry = remotes[directory], entry.configWritten == configWritten else { return nil }
        return .some(entry.remote)
    }

    func store(_ remote: GitLabRemote?, in directory: String, configWritten: Date?) {
        remotes[directory] = (configWritten, remote)
    }
}
