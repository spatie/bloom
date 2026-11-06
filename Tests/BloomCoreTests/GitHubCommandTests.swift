import Foundation
import Testing
@testable import BloomCore

/// Every `gh` command run through `GitHub.run`, pinned argument by argument, before
/// `repositoryArguments` adds `--repo` (see `GitHubRepositoryResolutionTests`). `gh auth status`
/// and `gh api user` call `Shell` directly and cannot be seen from here.
@Suite("GitHub commands", .scratchDirectory)
struct GitHubCommandTests {
    private static let fields = "number,title,url,state,isDraft,mergeable,baseRefName,headRefOid,"
        + "mergeStateStatus,reviewDecision,headRefName,statusCheckRollup,closedAt"
    private static let fieldsWithoutChecks = "number,title,url,state,isDraft,mergeable,baseRefName,headRefOid,"
        + "mergeStateStatus,reviewDecision,headRefName,closedAt"
    private static let listingFields = "number,title,author,headRefName,baseRefName,"
        + "isDraft,state,isCrossRepository,headRepositoryOwner"
    private static let pullRequest = #"{"number":42,"title":"Work","url":"https://github.com/acme/app/pull/42","state":"OPEN","isDraft":false,"headRefName":"feature","statusCheckRollup":[]}"#
    private static let listing = #"{"number":7,"title":"Fix","author":{"login":"someone"},"headRefName":"fix","baseRefName":"main","isDraft":false,"state":"OPEN","isCrossRepository":false}"#
    private static let noPullRequest = ShellResult(status: 1, stdout: "", stderr: "no pull requests found for branch \"feature\"")

    @Test("a pull request is read by branch")
    func viewByBranch() async throws {
        let commands = try await record(answer: Self.pullRequest) { worktree in
            _ = try await GitHub.snapshot(forBranch: "feature", worktree: worktree, maxAge: .zero)
        }
        #expect(commands == [["pr", "view", "feature", "--json", Self.fields]])
    }

    @Test("a branch with no pull request is asked again without naming it")
    func viewOfCheckedOutBranch() async throws {
        let commands = try await record(result: Self.noPullRequest) { worktree in
            _ = try await GitHub.snapshot(forBranch: "feature", worktree: worktree, maxAge: .zero)
        }
        #expect(commands == [
            ["pr", "view", "feature", "--json", Self.fields],
            ["pr", "view", "--json", Self.fields],
        ])
    }

    @Test("a pull request is read by number")
    func viewByNumber() async throws {
        let commands = try await record(answer: Self.pullRequest) { worktree in
            _ = try await GitHub.snapshot(forNumber: 42, worktree: worktree, maxAge: .zero)
        }
        #expect(commands == [["pr", "view", "42", "--json", Self.fields]])
    }

    @Test("refused check runs are asked for again without the rollup")
    func viewWithoutChecks() async throws {
        let refusal = ShellResult(
            status: 1, stdout: "",
            stderr: "GraphQL: Resource not accessible by personal access token (repository.pullRequest.statusCheckRollup)"
        )
        let commands = try await record { arguments in
            arguments.contains(Self.fields) ? refusal : ShellResult(status: 0, stdout: Self.pullRequest, stderr: "")
        } operation: { worktree in
            _ = try await GitHub.snapshot(forNumber: 42, worktree: worktree, maxAge: .zero)
        }
        #expect(commands == [
            ["pr", "view", "42", "--json", Self.fields],
            ["pr", "view", "42", "--json", Self.fieldsWithoutChecks],
        ])
    }

    @Test("the pull requests a head branch ever had are listed")
    func listByHead() async throws {
        let commands = try await record(answer: "[]") { worktree in
            _ = try await GitHub.pullRequestsWithHead("feature", worktree: worktree)
        }
        #expect(commands == [[
            "pr", "list", "--head", "feature", "--state", "all", "--limit", "20", "--json", "number,closedAt",
        ]])
    }

    @Test("a draft is marked ready by its address")
    func markReady() async throws {
        let draft = PullRequest(
            number: 42, title: "Work", url: "https://github.com/acme/app/pull/42", state: "OPEN", isDraft: true
        )
        let commands = try await record(answer: "") { worktree in
            try await GitHub.markReadyForReview(draft, worktree: worktree)
        }
        #expect(commands == [["pr", "ready", "https://github.com/acme/app/pull/42"]])
    }

    @Test("a pull request is created, then read back")
    func create() async throws {
        let commands = try await record(answer: Self.pullRequest) { worktree in
            _ = try await GitHub.createPullRequest(
                worktree: worktree, base: "main", title: "Title", body: "Body", draft: true
            )
        }
        #expect(commands == [
            ["pr", "create", "--base", "main", "--title", "Title", "--body", "Body", "--draft"],
            ["pr", "view", "--json", Self.fields],
        ])
    }

    @Test("a pull request is created from its pushed commits, then read back")
    func createFromCommits() async throws {
        let commands = try await record(answer: Self.pullRequest) { worktree in
            _ = try await GitHub.createPullRequestFromCommits(worktree: worktree, base: "main", title: "Title")
        }
        #expect(commands == [
            ["pr", "create", "--base", "main", "--title", "Title", "--fill"],
            ["pr", "view", "--json", Self.fields],
        ])
    }

    @Test("a failed run's log is read for its failed steps first, then whole", arguments: [
        (target: CheckFailureHandoff.LogTarget(runID: "123"), selector: ["123"]),
        (target: CheckFailureHandoff.LogTarget(runID: "123", jobID: "456"), selector: ["--job", "456"]),
    ])
    func runLog(target: CheckFailureHandoff.LogTarget, selector: [String]) async throws {
        let commands = try await record { arguments in
            ShellResult(status: 0, stdout: arguments.contains("--log") ? "the log" : "", stderr: "")
        } operation: { worktree in
            _ = try await GitHub.checkRunLog(target, worktree: worktree)
        }
        #expect(commands == [
            ["run", "view"] + selector + ["--log-failed"],
            ["run", "view"] + selector + ["--log"],
        ])
    }

    @Test("a pull request is summarised by number for the create window")
    func summary() async throws {
        let commands = try await record(answer: Self.listing) { repository in
            _ = try await GitHub.pullRequestSummary(number: 7, repoPath: repository)
        }
        #expect(commands == [["pr", "view", "7", "--json", Self.listingFields]])
    }

    @Test("a repository with no readable remote asks gh for its name")
    func slug() async throws {
        let commands = try await record(answer: "acme/app\n") { repository in
            _ = await GitHub.repositorySlug(repoPath: repository)
        }
        #expect(commands == [["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"]])
    }

    @Test("a pull request is checked out onto a named branch")
    func checkout() async throws {
        let commands = try await record(answer: "") { worktree in
            try await GitHub.checkoutPullRequest(number: 7, into: worktree, localBranch: "review/7")
        }
        #expect(commands == [["pr", "checkout", "7", "--branch", "review/7"]])
    }

    @Test("the accounts a repository could belong to")
    func owners() async throws {
        let commands = try await record { arguments in
            ShellResult(status: 0, stdout: arguments == ["api", "user"] ? #"{"login":"someone"}"# : "[]", stderr: "")
        } operation: { _ in
            _ = try await GitHub.owners()
        }
        #expect(commands == [["api", "user"], ["api", "user/orgs", "--paginate"]])
    }

    @Test("a repository name is checked, then created and given an address")
    func repositoryCreation() async throws {
        let commands = try await record(answer: "") { _ in
            _ = await GitHub.repositoryAvailability(owner: "acme", name: "app")
            _ = try await GitHub.createRepository(owner: "acme", name: "app", isPrivate: true)
        }
        #expect(commands == [
            ["api", "--silent", "repos/acme/app"],
            ["repo", "create", "acme/app", "--private"],
            ["config", "get", "git_protocol"],
        ])
    }

    private func record(
        answer stdout: String, operation: (String) async throws -> Void
    ) async throws -> [[String]] {
        try await record(result: ShellResult(status: 0, stdout: stdout, stderr: ""), operation: operation)
    }

    private func record(
        result: ShellResult, operation: (String) async throws -> Void
    ) async throws -> [[String]] {
        try await record({ _ in result }, operation: operation)
    }

    /// The gh commands `operation` ran, in order, each answered by `respond`.
    private func record(
        _ respond: @escaping @Sendable ([String]) -> ShellResult,
        operation: (String) async throws -> Void
    ) async throws -> [[String]] {
        let worktree = TestScratch.unique("gh-command")
        let log = CommandLog()
        try await GitHub.$commandOverride.withValue({ arguments, _ in
            await log.append(arguments)
            return respond(arguments)
        }) {
            try await operation(worktree)
        }
        return await log.commands
    }
}

private actor CommandLog {
    private(set) var commands: [[String]] = []

    func append(_ arguments: [String]) {
        commands.append(arguments)
    }
}
