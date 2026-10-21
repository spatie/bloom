import Foundation

/// Why GitLab will refuse a merge request that is open, not a draft and not conflicting, read
/// from `detailed_merge_status`. The GitHub decoder never fills it.
public enum MergeBlocker: Sendable, Hashable, Codable {
    case approvalRequired
    case changesRequested
    case unresolvedDiscussions
    case needsRebase
    case pipelineMustPass
    case pipelineRunning
    case blockedByMergeRequest
    case notBefore
    case checking
    /// A project rule in GitLab's words. An unknown status lands here: a refusal, never mergeable.
    case policy(String)

    /// Nil for `mergeable` and for what `PullRequest` already says (conflict, draft, not open).
    public init?(detailedMergeStatus status: String) {
        switch status {
        case "mergeable", "conflict", "draft_status", "not_open", "": return nil
        case "not_approved": self = .approvalRequired
        case "requested_changes": self = .changesRequested
        case "discussions_not_resolved": self = .unresolvedDiscussions
        case "need_rebase": self = .needsRebase
        case "ci_must_pass", "status_checks_must_pass", "security_policy_pipeline_check":
            self = .pipelineMustPass
        case "ci_still_running": self = .pipelineRunning
        case "merge_request_blocked": self = .blockedByMergeRequest
        case "merge_time": self = .notBefore
        case "checking", "unchecked", "preparing", "approvals_syncing": self = .checking
        default: self = .policy(status)
        }
    }

    /// The strip's headline.
    public var text: String {
        switch self {
        case .approvalRequired: "Waiting for approval"
        case .changesRequested: "Changes requested"
        case .unresolvedDiscussions: "Unresolved threads"
        case .needsRebase: "Needs rebase"
        case .pipelineMustPass: "Pipeline must pass"
        case .pipelineRunning: "Pipeline running"
        case .blockedByMergeRequest: "Blocked by another merge request"
        case .notBefore: "Scheduled"
        case .checking: "Checking mergeability"
        case .policy: "Blocked by GitLab"
        }
    }

    /// Why the merge button is off, for its tooltip.
    public var reason: String {
        switch self {
        case .approvalRequired: "This merge request needs an approval first."
        case .changesRequested: "A reviewer has requested changes."
        case .unresolvedDiscussions: "Resolve the open threads first."
        case .needsRebase: "Rebase this branch onto its target first."
        case .pipelineMustPass: "The pipeline has to succeed before this can merge."
        case .pipelineRunning: "Wait for the pipeline to finish."
        case .blockedByMergeRequest: "Another merge request has to merge first."
        case .notBefore: "This merge request is set to merge later."
        case .checking: "GitLab is still working out whether this can merge."
        case .policy(let status):
            "GitLab will not merge this yet: \(status.replacingOccurrences(of: "_", with: " "))."
        }
    }
}
