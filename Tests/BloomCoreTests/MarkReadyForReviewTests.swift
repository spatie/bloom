import Testing
@testable import BloomCore

@Suite("Mark ready for review")
struct MarkReadyForReviewTests {
    @Test("drafts offer ready for review regardless of their checks", arguments: [
        PullRequest.Checks.none, .pending, .failing, .passing,
    ])
    func draftsOfferReady(checks: PullRequest.Checks) {
        var request = draft()
        request.checks = checks

        #expect(request.status.remedy == .markReadyForReview)
        #expect(!request.status.canMerge)

        request.isDraft = false
        #expect(request.status.remedy == .merge)
        #expect(request.status.canMerge)
    }

    @Test("conflicts and local changes keep their existing actions")
    func precedingActions() {
        #expect(draft().status(local: LocalWork(modifiedFiles: 1)).remedy == .commitAndPush)
        #expect(draft().status(local: LocalWork(unpushedCommits: 1)).remedy == .push)

        var request = draft()
        request.mergeable = "CONFLICTING"
        #expect(request.status.remedy == .fixConflicts)
    }

    @Test("closed and merged drafts never offer ready for review", arguments: ["CLOSED", "MERGED"])
    func finishedRequests(state: String) {
        var request = draft()
        request.state = state

        #expect(request.status.remedy != .markReadyForReview)
        #expect(!request.status.canMerge)
    }

    @Test("non-draft and finished pull requests are refused before running gh", arguments: [
        ("OPEN", false), ("CLOSED", true), ("MERGED", true),
    ])
    func refusesInvalidRequest(state: String, isDraft: Bool) async {
        var request = draft()
        request.state = state
        request.isDraft = isDraft

        do {
            try await GitHub.markReadyForReview(request, worktree: "/nonexistent")
            Issue.record("An invalid pull request should be refused")
        } catch let error as GitHubError {
            #expect(error.message == "This pull request is no longer an open draft.")
        } catch {
            Issue.record("Expected refusal before running gh, got: \(error)")
        }
    }

    private func draft() -> PullRequest {
        PullRequest(
            number: 42, title: "Fix the updater", url: "https://github.com/example/bloom/pull/42",
            state: "OPEN", isDraft: true, mergeable: "MERGEABLE", checks: .passing,
            checksSummary: "3 checks passed", reviewDecision: nil, branch: "fix-updater"
        )
    }
}
