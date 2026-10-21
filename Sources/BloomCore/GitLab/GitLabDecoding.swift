import Foundation

/// GitLab's REST answers in GitHub's vocabulary (`opened` is `OPEN`, a job is a check run), so
/// everything downstream is shared. What GitHub has no word for goes in `blockers`.
enum GitLabDecoding {
    struct MergeRequestPayload: Decodable {
        struct Pipeline: Decodable {
            let id: Int
            /// The project the pipeline ran in, which for a merge request from a fork is the fork.
            let projectId: Int?
            let status: String?
        }

        struct Author: Decodable {
            let username: String?
        }

        let iid: Int?
        let title: String?
        let webUrl: String?
        let state: String?
        let draft: Bool?
        let hasConflicts: Bool?
        let detailedMergeStatus: String?
        let sourceBranch: String?
        let targetBranch: String?
        /// The source branch's head commit, which a direct merge passes as `--sha`.
        let sha: String?
        let mergedAt: String?
        let closedAt: String?
        let sourceProjectId: Int?
        let targetProjectId: Int?
        let headPipeline: Pipeline?
        let author: Author?
    }

    struct JobPayload: Decodable {
        let id: Int?
        let name: String?
        let stage: String?
        let status: String?
        let allowFailure: Bool?
        let webUrl: String?
        let startedAt: String?
        let finishedAt: String?
    }

    struct CommitPayload: Decodable, Equatable {
        let sha: String?

        enum CodingKeys: String, CodingKey {
            case sha = "id"
        }
    }

    static func commits(from data: Data) throws -> [CommitPayload] {
        try decode([CommitPayload].self, from: data)
    }

    static func mergeRequest(from data: Data) throws -> MergeRequestPayload {
        try decode(MergeRequestPayload.self, from: data)
    }

    static func mergeRequests(from data: Data) throws -> [MergeRequestPayload] {
        try decode([MergeRequestPayload].self, from: data)
    }

    static func jobs(from data: Data) throws -> [CheckRun] {
        try decode([JobPayload].self, from: data).map(checkRun)
    }

    /// `runs` is nil when the pipeline's jobs could not be read.
    static func pullRequest(_ payload: MergeRequestPayload, runs: [CheckRun]?) -> PullRequest {
        let detailed = payload.detailedMergeStatus ?? ""
        let state = state(payload.state)
        let (checks, rollup) = runs.map(GitHub.rollup) ?? (.unavailable, "Pipeline unavailable")
        // GitLab's word for a check run is a job.
        let summary = rollup.replacingOccurrences(of: "check", with: "job")
        return PullRequest(
            number: payload.iid ?? 0,
            title: payload.title ?? "",
            url: payload.webUrl ?? "",
            state: state,
            isDraft: payload.draft ?? false,
            mergeable: payload.hasConflicts == true || detailed == "conflict" ? "CONFLICTING" : nil,
            checks: checks,
            checksSummary: summary,
            reviewDecision: reviewDecision(detailed),
            branch: payload.sourceBranch ?? "",
            baseBranch: payload.targetBranch,
            headRevision: payload.sha,
            // GitLab leaves `closed_at` null on a merge; ownership needs it set, as GitHub does.
            closedAt: date(payload.mergedAt) ?? date(payload.closedAt),
            forge: .gitLab,
            blockers: state == "OPEN" ? MergeBlocker(detailedMergeStatus: detailed).map { [$0] } ?? [] : []
        )
    }

    static func listing(_ payload: MergeRequestPayload) -> PullRequestListing {
        let isFork = payload.sourceProjectId != nil && payload.sourceProjectId != payload.targetProjectId
        let author = payload.author?.username ?? ""
        return PullRequestListing(
            number: payload.iid ?? 0,
            title: payload.title ?? "",
            author: author,
            headRefName: payload.sourceBranch ?? "",
            baseRefName: payload.targetBranch ?? "",
            isDraft: payload.draft ?? false,
            state: state(payload.state),
            isCrossRepository: isFork,
            // Usually the fork's namespace; only the local branch name uses it.
            headRepositoryOwner: isFork ? author : nil
        )
    }

    static func state(_ value: String?) -> String {
        switch value {
        case "opened": "OPEN"
        case "merged": "MERGED"
        case "closed", "locked": "CLOSED"
        default: value?.uppercased() ?? "UNKNOWN"
        }
    }

    private static func reviewDecision(_ detailed: String) -> String? {
        switch detailed {
        case "not_approved": "REVIEW_REQUIRED"
        case "requested_changes": "CHANGES_REQUESTED"
        default: nil
        }
    }

    private static func checkRun(_ job: JobPayload) -> CheckRun {
        let (status, conclusion) = outcome(job.status)
        return CheckRun(
            name: job.name ?? "Job",
            status: status,
            conclusion: conclusion,
            detailsURL: job.webUrl,
            startedAt: date(job.startedAt),
            completedAt: date(job.finishedAt),
            workflowName: job.stage,
            isRequired: !(job.allowFailure ?? false)
        )
    }

    private static func outcome(_ status: String?) -> (status: String, conclusion: String?) {
        switch status {
        case "success": ("COMPLETED", "SUCCESS")
        case "failed": ("COMPLETED", "FAILURE")
        case "canceled", "canceling": ("COMPLETED", "CANCELLED")
        case "skipped", "manual": ("COMPLETED", "SKIPPED")
        case "running": ("IN_PROGRESS", nil)
        default: ("QUEUED", nil)
        }
    }

    private static func date(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
            ?? (try? Date.ISO8601FormatStyle(includingFractionalSeconds: false).parse(value))
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(type, from: data)
        } catch {
            let raw = String(decoding: data.suffix(1_024), as: UTF8.self)
            throw GitHubError("Could not decode GitLab JSON: \(error). Raw JSON tail: \(raw)")
        }
    }
}
