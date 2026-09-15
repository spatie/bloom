import Foundation
import Testing
@testable import BloomCore

/// A fine-grained personal access token cannot read check runs, and GitHub fails the whole
/// `gh pr view` over them. The pull request still has to arrive, with its checks marked unknown
/// rather than missing, and unknown must never read as passing.
@Suite("Checks a token cannot read", .scratchDirectory)
struct UnreadableChecksTests {
    private static let refusal = "GraphQL: Resource not accessible by personal access token "
        + "(repository.pullRequest.statusCheckRollup.nodes.0.commit.statusCheckRollup.contexts.nodes.0), "
        + "Resource not accessible by personal access token "
        + "(repository.pullRequest.statusCheckRollup.nodes.0.commit.statusCheckRollup.contexts.nodes.1)"
    private static let metadata = #"{"number":42,"title":"Work","url":"https://github.com/org/repo/pull/42","state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","reviewDecision":"REVIEW_REQUIRED","headRefName":"feature","closedAt":null}"#

    @Test("a refused rollup is asked again without it, and the next poll does not ask for it")
    func retriesWithoutTheRollup() async throws {
        let worktree = TestScratch.unique("unreadable-checks")
        let asked = Counter()
        let found = try await GitHub.$commandOverride.withValue({ arguments, _ in
            await asked.increment()
            if arguments.joined(separator: " ").contains("statusCheckRollup") {
                return ShellResult(status: 1, stdout: "", stderr: Self.refusal)
            }
            return ShellResult(status: 0, stdout: Self.metadata, stderr: "")
        }) {
            try await GitHub.snapshot(forNumber: 42, worktree: worktree, maxAge: .zero)
        }
        let snapshot = try #require(found)
        #expect(snapshot.pullRequest.number == 42)
        #expect(snapshot.pullRequest.branch == "feature")
        #expect(snapshot.pullRequest.checks == .unavailable)
        #expect(snapshot.pullRequest.checksSummary == GitHub.checksUnavailableSummary)
        #expect(snapshot.runs.isEmpty)
        #expect(await asked.count == 2)

        let again = try await GitHub.$commandOverride.withValue({ arguments, _ in
            if arguments.joined(separator: " ").contains("statusCheckRollup") {
                Issue.record("A refused rollup should not be asked for again on the next poll")
            }
            return ShellResult(status: 0, stdout: Self.metadata, stderr: "")
        }) {
            try await GitHub.snapshot(forNumber: 42, worktree: worktree, maxAge: .zero)
        }
        #expect(again?.pullRequest.checks == .unavailable)
    }

    @Test("a refusal that is not about the rollup stays a failure")
    func otherRefusals() async {
        let worktree = TestScratch.unique("refused-pull-request")
        await #expect(throws: ShellError.self) {
            try await GitHub.$commandOverride.withValue({ _, _ in
                ShellResult(
                    status: 1, stdout: "",
                    stderr: "GraphQL: Resource not accessible by personal access token (repository.pullRequest)"
                )
            }) {
                try await GitHub.snapshot(forNumber: 42, worktree: worktree, maxAge: .zero)
            }
        }
    }

    @Test("unknown checks are neither no checks nor passing")
    func unknownIsNotPassing() {
        let pullRequest = PullRequest(
            number: 42, title: "Work", url: "https://github.com/org/repo/pull/42", state: "OPEN",
            checks: .unavailable, checksSummary: GitHub.checksUnavailableSummary
        )
        #expect(pullRequest.status.text == "Checks unavailable")
        #expect(pullRequest.status.tone != .positive)
        #expect(pullRequest.mergeWarnings(base: "main").contains { $0.contains("checks") })
        #expect(InspectorTab.hasChecks(pullRequest))
    }
}

private actor Counter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}
