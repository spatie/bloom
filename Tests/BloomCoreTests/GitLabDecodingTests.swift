import Foundation
import Testing
@testable import BloomCore

/// Against real REST answers from gitlab.com (`gitlab-org/cli`, 2026-10-08), trimmed to the
/// fields Bloom reads and with authors anonymised. See `Tests/fixtures/gitlab`.
@Suite("GitLab decoding")
struct GitLabDecodingTests {
    @Test("an open merge request waiting for approval, with a failed pipeline")
    func waitingForApproval() throws {
        let pullRequest = try decode("mr-not-approved.json", jobs: "jobs-failed-pipeline.json")
        #expect(pullRequest.number == 4021)
        #expect(pullRequest.state == "OPEN")
        #expect(pullRequest.forge == .gitLab)
        #expect(pullRequest.branch == "phikai/8524-validate-api-repo-urls")
        #expect(pullRequest.baseBranch == "main")
        #expect(pullRequest.headRevision == "d7be98ed462c3011d7fd47a92f0dd1257ec6fdbb")
        #expect(pullRequest.reviewDecision == "REVIEW_REQUIRED")
        #expect(pullRequest.blockers == [.approvalRequired])
        #expect(pullRequest.checks == .failing)
        #expect(pullRequest.checksSummary == "1 required job failed")
        #expect(pullRequest.status.text == "Waiting for approval")
        #expect(pullRequest.status.canMerge == false)
        #expect(pullRequest.status.blockedReason == "This merge request needs an approval first.")
    }

    @Test("a conflict outranks the draft, as it does on GitHub")
    func draftAndConflicting() throws {
        let pullRequest = try decode("mr-draft-conflicting-fork.json")
        #expect(pullRequest.isDraft)
        #expect(pullRequest.hasConflicts)
        #expect(pullRequest.blockers.isEmpty)
        #expect(pullRequest.status.text == "Merge conflicts")
    }

    @Test("a merged merge request ended when it merged")
    func merged() throws {
        let pullRequest = try decode("mr-merged.json")
        #expect(pullRequest.isMerged)
        #expect(pullRequest.closedAt != nil)
        #expect(pullRequest.blockers.isEmpty)
        #expect(pullRequest.status.blockedReason == "This merge request is already merged.")
        #expect(WorkspaceStatus.merged.summary(pullRequest: pullRequest) == "Merged, merge request !4015: No jobs")
    }

    @Test("unresolved threads block the merge")
    func unresolvedThreads() throws {
        let pullRequest = try decode("mr-unresolved-discussions.json")
        #expect(pullRequest.blockers == [.unresolvedDiscussions])
        #expect(pullRequest.status.text == "Unresolved threads")
    }

    @Test("jobs become check runs, required unless allowed to fail")
    func jobs() throws {
        let runs = try GitLabDecoding.jobs(from: fixture("jobs-failed-pipeline.json"))
        #expect(runs.count == 18)
        let failed = try #require(runs.first { $0.name == "tests:unit" })
        #expect(failed.status == "COMPLETED")
        #expect(failed.conclusion == "FAILURE")
        #expect(failed.isRequired)
        #expect(failed.workflowName == "test")
        let manual = try #require(runs.first { $0.name == "review-docs-deploy" })
        #expect(manual.conclusion == "SKIPPED")
        #expect(manual.isRequired == false)
    }

    @Test("a merge request from a fork is listed as one")
    func listing() throws {
        let payloads = try GitLabDecoding.mergeRequests(from: fixture("mr-list-open.json"))
        let first = GitLabDecoding.listing(try #require(payloads.first))
        #expect(first.number == 4038)
        #expect(first.headRefName == "anishisbusy/repo-create-topics")
        #expect(first.baseRefName == "main")
        #expect(first.isCrossRepository)
        #expect(first.headRepositoryOwner == "contributor-1")
        #expect(first.state == "OPEN")
    }

    private static let statuses: [(status: String, blocker: MergeBlocker?)] = [
        (status: "mergeable", blocker: nil),
        (status: "conflict", blocker: nil),
        (status: "draft_status", blocker: nil),
        (status: "not_open", blocker: nil),
        (status: "not_approved", blocker: .approvalRequired),
        (status: "requested_changes", blocker: .changesRequested),
        (status: "need_rebase", blocker: .needsRebase),
        (status: "ci_must_pass", blocker: .pipelineMustPass),
        (status: "ci_still_running", blocker: .pipelineRunning),
        (status: "merge_request_blocked", blocker: .blockedByMergeRequest),
        (status: "merge_time", blocker: .notBefore),
        (status: "unchecked", blocker: .checking),
        (status: "jira_association_missing", blocker: .policy("jira_association_missing")),
        (status: "something_new", blocker: .policy("something_new")),
    ]

    @Test("every detailed merge status has a meaning, and an unknown one refuses", arguments: statuses)
    func blockers(status: String, blocker: MergeBlocker?) {
        #expect(MergeBlocker(detailedMergeStatus: status) == blocker)
    }

    @Test("a GitHub pull request never carries a blocker")
    func gitHubHasNone() throws {
        let pullRequest = try GitHub.decodePullRequest(from: Data(
            #"{"number":1,"title":"PR","url":"https://github.com/a/b/pull/1","state":"OPEN","mergeStateStatus":"BLOCKED"}"#.utf8
        ))
        #expect(pullRequest.forge == .gitHub)
        #expect(pullRequest.blockers.isEmpty)
    }

    @Test("a GitLab merge request's number is written down, so a renamed branch keeps it")
    func numberRecorded() {
        let gitLab = PullRequest(number: 12, title: "", url: "", state: "OPEN", forge: .gitLab)
        #expect(PullRequestNumber.toRecord(found: gitLab, recorded: nil) == 12)
    }

    @Test("a GitLab job page names its job and the project it ran in")
    func jobLogTarget() {
        let target = CheckFailureHandoff.logTarget(detailsURL: "https://gitlab.com/group/sub/app/-/jobs/17015172335")
        #expect(target == CheckFailureHandoff.LogTarget(
            runID: "17015172335", jobID: "17015172335", project: "group/sub/app"
        ))
        #expect(CheckFailureHandoff.logTarget(detailsURL: "https://gitlab.com/group/app/-/pipelines/1") == nil)
    }

    private func decode(_ name: String, jobs: String? = nil) throws -> PullRequest {
        let payload = try GitLabDecoding.mergeRequest(from: fixture(name))
        let runs = try jobs.map { try GitLabDecoding.jobs(from: fixture($0)) } ?? []
        return GitLabDecoding.pullRequest(payload, runs: runs)
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(bloomFixtureURL("gitlab/\(name)"))
        return try Data(contentsOf: url)
    }
}
