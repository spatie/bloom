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

    @Test("the turn targets the exact pull request and stops after clearing draft status")
    func readyPrompt() {
        let request = draft()
        let render = PromptTemplate.render(
            PromptRegistry.definition(for: .markReadyForReview).defaultTemplate,
            values: [PromptRegistry.MarkReadyForReview.url: request.url]
        )

        #expect(render.unknown.isEmpty)
        #expect(render.missing.isEmpty)
        #expect(render.text.contains(request.url))
        #expect(render.text.contains("gh pr ready"))
        #expect(render.text.contains("verify its draft status is cleared"))
        #expect(render.text.contains("Do not merge the pull request, commit or push changes"))
    }

    private func draft() -> PullRequest {
        PullRequest(
            number: 42, title: "Fix the updater", url: "https://github.com/example/bloom/pull/42",
            state: "OPEN", isDraft: true, mergeable: "MERGEABLE", checks: .passing,
            checksSummary: "3 checks passed", reviewDecision: nil, branch: "fix-updater"
        )
    }
}
