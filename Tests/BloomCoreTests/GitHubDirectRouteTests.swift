import Foundation
import Testing
@testable import BloomCore

/// What the direct routes say when Bloom runs gh itself, word for word: every refusal before
/// `gh pr merge` runs, the outcomes after it, and a create refused because one exists.
@Suite("GitHub direct routes", .tags(.git), .scratchDirectory)
struct GitHubDirectRouteTests {
    enum Refusal: String, CaseIterable, Sendable {
        case unrefreshed, otherBranch, localWork, otherHead, otherBase, changed, closed
    }

    @Test("each refusal before gh merges", arguments: Refusal.allCases)
    func refusal(_ refusal: Refusal) async throws {
        let repo = try await featureRepo()
        defer { repo.cleanUp() }
        let head = try await Git.headSHA(of: repo.path)
        let other = String(repeating: "a", count: 40)
        if refusal == .localWork { try repo.write("untracked.txt", "keep\n") }
        let gh = DirectGH(
            head: refusal == .changed ? other : head, state: refusal == .closed ? "CLOSED" : "OPEN"
        )
        let expected = pullRequest(
            branch: refusal == .otherBranch ? "other" : "feature",
            base: refusal == .otherBase ? "develop" : "main",
            head: refusal == .unrefreshed ? nil : refusal == .otherHead ? other : head
        )

        do {
            _ = try await GitHub.$commandOverride.withValue({ arguments, _ in
                await gh.execute(arguments)
            }) {
                try await GitHub.mergePullRequest(expected, into: "main", method: .squash, worktree: repo.path)
            }
            Issue.record("\(refusal) was merged")
        } catch let error as GitHubError {
            #expect(error.message == Self.messages[refusal])
        }
        #expect(await gh.merges == 0)
    }

    private static let messages: [Refusal: String] = [
        .unrefreshed: "Refresh the pull request before merging directly.",
        .otherBranch: "This worktree is no longer on the pull request's branch.",
        .localWork: "This worktree has changes or commits GitHub has not got. Commit and push them, or choose the agent route after reviewing the warning.",
        .otherHead: "This checkout is not at the pull request's head commit. Refresh or update it before merging directly.",
        .otherBase: "The pull request targets develop, not main. Refresh it before merging.",
        .changed: "The pull request changed since it was shown. Refresh it before merging.",
        .closed: "This pull request was closed without merging.",
    ]

    @Test("a merge gh accepted is merged, still open, or unverified, and a refused one that landed is merged")
    func outcomes() async throws {
        let repo = try await featureRepo()
        defer { repo.cleanUp() }
        let head = try await Git.headSHA(of: repo.path)
        let cases: [(gh: DirectGH, outcome: DirectMergeOutcome)] = [
            (DirectGH(head: head, after: .merged), .merged),
            (DirectGH(head: head, after: .stillOpen), .acceptedButOpen),
            (DirectGH(head: head, after: .unreadable), .acceptedUnverified),
            (DirectGH(head: head, after: .merged, mergeFails: true), .merged),
        ]
        for (gh, outcome) in cases {
            let merged = try await GitHub.$commandOverride.withValue({ arguments, _ in
                await gh.execute(arguments)
            }) {
                try await GitHub.mergePullRequest(
                    pullRequest(branch: "feature", base: "main", head: head),
                    into: "main", method: .merge, worktree: repo.path
                )
            }
            #expect(merged == outcome)
        }
    }

    @Test("a create stops before committing when the branch already has a pull request")
    func createRefusedWhenOneExists() async throws {
        let repo = try await featureRepo()
        defer { repo.cleanUp() }
        // A repository with no remote has no pull request to read, so gh would never be asked.
        try await Shell.check("git", ["remote", "add", "origin", "https://github.com/org/repo.git"], cwd: repo.path)
        try repo.write("work.txt", "work\n")
        let head = try await Git.headSHA(of: repo.path)
        let gh = DirectGH(head: head)
        let workspace = Workspace(
            repoID: RepoID("repo"), name: "work", branch: "feature", path: repo.path, baseBranch: "main"
        )

        do {
            _ = try await GitHub.$commandOverride.withValue({ arguments, _ in
                await gh.execute(arguments)
            }) {
                try await DirectPullRequestCreation.create(for: workspace)
            }
            Issue.record("A second pull request was created")
        } catch let error as GitHubError {
            #expect(error.message == "Pull request #42 already exists for this branch.")
        }
        #expect(await gh.creates == 0)
        #expect(try await Git.headSHA(of: repo.path) == head)
    }

    private func featureRepo() async throws -> TempRepo {
        let repo = try await TempRepo()
        try await Shell.check("git", ["checkout", "-q", "-b", "feature"], cwd: repo.path)
        return repo
    }

    private func pullRequest(branch: String, base: String, head: String?) -> PullRequest {
        PullRequest(
            number: 42, title: "Feature", url: "https://github.com/org/repo/pull/42",
            state: "OPEN", branch: branch, baseBranch: base, headRevision: head
        )
    }
}

/// gh for one pull request, #42 on `feature`, and what it says once a merge has been sent.
private actor DirectGH {
    enum After: Sendable { case merged, stillOpen, unreadable }

    private let head: String
    private let state: String
    private let after: After
    private let mergeFails: Bool
    private var sent = false
    private(set) var merges = 0
    private(set) var creates = 0

    init(head: String, state: String = "OPEN", after: After = .merged, mergeFails: Bool = false) {
        self.head = head
        self.state = state
        self.after = after
        self.mergeFails = mergeFails
    }

    func execute(_ arguments: [String]) -> ShellResult {
        if arguments.starts(with: ["pr", "merge"]) {
            merges += 1
            sent = true
            return ShellResult(status: mergeFails ? 1 : 0, stdout: "", stderr: mergeFails ? "refused" : "")
        }
        if arguments.starts(with: ["pr", "create"]) {
            creates += 1
            return ShellResult(status: 0, stdout: "", stderr: "")
        }
        if arguments.starts(with: ["pr", "list"]) {
            return ShellResult(status: 0, stdout: "[]", stderr: "")
        }
        if sent, after == .unreadable {
            return ShellResult(status: 1, stdout: "", stderr: "HTTP 502")
        }
        let current = sent && after == .merged ? "MERGED" : state
        return ShellResult(status: 0, stdout: """
            {"number":42,"title":"Feature","url":"https://github.com/org/repo/pull/42",\
            "state":"\(current)","isDraft":false,"mergeable":"MERGEABLE",\
            "headRefName":"feature","baseRefName":"main","headRefOid":"\(head)"}
            """, stderr: "")
    }
}
