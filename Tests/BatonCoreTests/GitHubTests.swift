import Foundation
import Testing
@testable import BatonCore

@Suite("GitHub")
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

    @Test("a failing required check fails the rollup")
    func requiredFailure() throws {
        let pullRequest = try decode(jsonWithChecks("""
        {"__typename":"CheckRun","name":"Tests","status":"COMPLETED","conclusion":"FAILURE","isRequired":true}
        """))
        #expect(pullRequest.checks == .failing)
        #expect(pullRequest.checksSummary == "1 required check failed")
    }

    @Test("an optional failure does not fail the rollup")
    func optionalFailure() throws {
        let pullRequest = try decode(jsonWithChecks("""
        {"__typename":"StatusContext","context":"preview","state":"FAILURE","isRequired":false}
        """))
        #expect(pullRequest.checks == .passing)
        #expect(pullRequest.checksSummary == "1 optional check failed")
    }

    @Test("queued and running checks are pending")
    func pending() throws {
        let pullRequest = try decode(jsonWithChecks("""
        {"__typename":"CheckRun","name":"Tests","status":"IN_PROGRESS","conclusion":null},
        {"__typename":"StatusContext","context":"deploy","state":"PENDING"}
        """))
        #expect(pullRequest.checks == .pending)
        #expect(pullRequest.checksSummary == "2 checks pending")
    }

    @Test("an empty rollup has no checks")
    func noChecks() throws {
        let pullRequest = try decode(jsonWithChecks(""))
        #expect(pullRequest.checks == .none)
        #expect(pullRequest.checksSummary == "No checks")
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
        #expect(!pullRequest.isDraft)
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
        #expect(!GitHub.indicatesNoPullRequest(stderr: "HTTP 503 service unavailable"))
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
