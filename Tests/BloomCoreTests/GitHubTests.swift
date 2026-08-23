import Foundation
import Testing
@testable import BloomCore

@Suite("GitHub", .tags(.agentProtocol))
struct GitHubTests {
    @Test("decodes all passing check shapes")
    func allPassing() throws {
        let pullRequest = try decode("""
        {
          "number": 42,
          "title": "Ship it",
          "url": "https://github.com/acme/app/pull/42",
          "state": "OPEN",
          "isDraft": false,
          "mergeable": "MERGEABLE",
          "reviewDecision": "APPROVED",
          "statusCheckRollup": [
            {
              "__typename": "CheckRun",
              "name": "Tests",
              "status": "COMPLETED",
              "conclusion": "SUCCESS",
              "detailsUrl": "https://github.com/acme/app/actions/runs/1",
              "startedAt": "2026-08-18T08:00:00Z",
              "completedAt": "2026-08-18T08:01:00Z",
              "workflowName": "CI",
              "isRequired": true
            },
            {
              "__typename": "StatusContext",
              "context": "coverage",
              "state": "SUCCESS",
              "targetUrl": "https://checks.example/1",
              "isRequired": false
            }
          ]
        }
        """)

        #expect(pullRequest.checks == .passing)
        #expect(pullRequest.checksSummary == "2 checks passed")
        #expect(pullRequest.reviewDecision == "APPROVED")
    }

    /// The rollup mixes two GraphQL node shapes, `CheckRun` (a GitHub Actions job) and
    /// `StatusContext` (a third-party commit status), and each spells its outcome differently.
    @Test("rolls a mixed set of check nodes up into one verdict", arguments: [
        (
            name: "a required failure fails the rollup",
            nodes: #"{"__typename":"CheckRun","name":"Tests","status":"COMPLETED","conclusion":"FAILURE","isRequired":true}"#,
            checks: PullRequest.Checks.failing,
            summary: "1 required check failed"
        ),
        (
            name: "an optional failure does not fail the rollup",
            nodes: #"{"__typename":"StatusContext","context":"preview","state":"FAILURE","isRequired":false}"#,
            checks: .passing,
            summary: "1 optional check failed"
        ),
        (
            name: "queued and running checks are pending",
            nodes: #"{"__typename":"CheckRun","name":"Tests","status":"IN_PROGRESS","conclusion":null},"#
                + #"{"__typename":"StatusContext","context":"deploy","state":"PENDING"}"#,
            checks: .pending,
            summary: "2 checks pending"
        ),
        (
            name: "an empty rollup has no checks",
            nodes: "",
            checks: .none,
            summary: "No checks"
        ),
    ])
    func rollsChecksUp(
        name: String, nodes: String, checks: PullRequest.Checks, summary: String
    ) throws {
        let pullRequest = try decode(jsonWithChecks(nodes))
        #expect(pullRequest.checks == checks, "\(name)")
        #expect(pullRequest.checksSummary == summary, "\(name)")
    }

    @Test("decodes a draft and a null review decision")
    func draftWithNullReview() throws {
        let pullRequest = try decode("""
        {"number":7,"title":"WIP","url":"https://example/7","state":"OPEN","isDraft":true,"reviewDecision":null,"statusCheckRollup":[]}
        """)
        #expect(pullRequest.isDraft)
        #expect(pullRequest.reviewDecision == nil)
    }

    @Test("missing optional fields use safe defaults")
    func missingFields() throws {
        let pullRequest = try decode("""
        {"number":8,"title":"Small PR","url":"https://example/8","state":"OPEN","statusCheckRollup":[{"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS"}]}
        """)
        #expect(pullRequest.isDraft == false)
        #expect(pullRequest.mergeable == nil)
        #expect(pullRequest.checks == .passing)
    }

    @Test("malformed JSON throws with raw output context")
    func malformedJSON() {
        #expect(throws: GitHubError.self) {
            try GitHub.decodePullRequest(from: Data("{not json".utf8))
        }
    }

    @Test("recognizes gh's missing pull request error")
    func noPullRequestError() {
        #expect(GitHub.indicatesNoPullRequest(stderr: "no pull requests found for branch feature"))
        #expect(GitHub.indicatesNoPullRequest(stderr: "HTTP 503 service unavailable") == false)
    }

    private func decode(_ json: String) throws -> PullRequest {
        try GitHub.decodePullRequest(from: Data(json.utf8))
    }

    private func jsonWithChecks(_ checks: String) -> String {
        """
        {"number":1,"title":"PR","url":"https://example/1","state":"OPEN","isDraft":false,"reviewDecision":null,"statusCheckRollup":[\(checks)]}
        """
    }
}
