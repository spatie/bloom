import Foundation
import Testing
@testable import BloomCore

@Suite("GitHub read reliability", .scratchDirectory)
struct GitHubReadReliabilityTests {
    @Test("a missing numbered PR is an answer, while transport and malformed output remain failures")
    func absenceVersusFailure() async throws {
        let missingPath = TestScratch.unique("missing-pr")
        let missing = try await GitHub.$commandOverride.withValue({ _, _ in
            ShellResult(status: 1, stdout: "", stderr: "GraphQL: Could not resolve to a PullRequest with the number of 123.")
        }) {
            try await GitHub.snapshot(forNumber: 123, worktree: missingPath, maxAge: .zero)
        }
        #expect(missing == nil)
        let cached = try await GitHub.$commandOverride.withValue({ _, _ in
            Issue.record("A confirmed absence should be cached")
            throw GitHubError("unexpected command")
        }) {
            try await GitHub.snapshot(forNumber: 123, worktree: missingPath, maxAge: .seconds(30))
        }
        #expect(cached == nil)

        let failedPath = TestScratch.unique("failed-pr")
        await #expect(throws: ShellError.self) {
            try await GitHub.$commandOverride.withValue({ _, _ in
                ShellResult(status: 1, stdout: "", stderr: "error connecting to github.com")
            }) {
                try await GitHub.snapshot(forNumber: 123, worktree: failedPath, maxAge: .zero)
            }
        }
        await #expect(throws: (any Error).self) {
            try await GitHub.$commandOverride.withValue({ _, _ in
                ShellResult(status: 0, stdout: "{broken", stderr: "")
            }) {
                // If the transport failure had been cached as nil, this would return nil.
                try await GitHub.snapshot(forNumber: 123, worktree: failedPath, maxAge: .seconds(30))
            }
        }
    }

    @Test("refresh failures retain content and a successful absence clears it")
    func displayedState() {
        let pullRequest = PullRequest(number: 123, title: "Work", url: "https://github.com/org/repo/pull/123", state: "OPEN", branch: "feature")
        var state = PullRequestRefreshState(pullRequest: pullRequest)
        let failure = GitHubReadFailure(reason: .unavailable, message: "Could not connect")
        state.record(.unavailable(failure))
        #expect(state.pullRequest == pullRequest)
        #expect(state.failure == failure)
        state.record(.current(nil))
        #expect(state.pullRequest == nil)
        #expect(state.failure == nil)
    }

    @Test("identical concurrent reads execute once", .timeLimit(.minutes(1)))
    func sharedRead() async throws {
        let requests = GitHubRequests()
        let probe = ReadProbe()
        let key = GitHubRequests.Key(host: "github.com", directory: "shared", arguments: ["pr", "view", "1"])
        let readers = Task {
            try await withThrowingTaskGroup(of: ShellResult.self) { group in
                for _ in 0..<20 {
                    group.addTask {
                        try await requests.run(key: key, interactive: false) { await probe.execute() }
                    }
                }
                var results: [ShellResult] = []
                for try await result in group { results.append(result) }
                return results
            }
        }
        await probe.waitUntilStarted()
        // Release only after every caller is actually subscribed, not after a guessed delay.
        while await requests.activeSubscribers < 20 { await Task.yield() }
        await probe.release()
        let results = try await readers.value
        #expect(results.count == 20)
        #expect(await probe.count == 1)
    }

    @Test("a cancelled subscriber leaves promptly without cancelling a shared request")
    func cancelledSubscriber() async throws {
        let probe = ReadProbe()
        let underlying = Task<ShellResult, Error> { await probe.execute() }
        await probe.waitUntilStarted()
        let subscriber = Task { try await GitHubRequestWaiter.value(of: underlying) }
        subscriber.cancel()
        await #expect(throws: CancellationError.self) { try await subscriber.value }
        #expect(!underlying.isCancelled)
        await probe.release()
        let result = try await underlying.value
        #expect(result.stdout == "answer")
    }

    @Test("checkout and run logs use the same base repository as PR reads")
    func repositoryRouting() {
        let context = GitRepositoryContext.resolve(config: [
            "remote.origin.url": "git@github.com:person/project.git",
            "remote.upstream.url": "https://github.com/organisation/project.git",
            "branch.main.remote": "upstream",
        ], base: "main", branch: "feature")
        #expect(GitHub.repositoryArguments(["pr", "checkout", "123"], context: context)
            == ["pr", "checkout", "123", "--repo", "github.com/organisation/project"])
        #expect(GitHub.repositoryArguments(["run", "view", "456", "--log"], context: context)
            == ["run", "view", "456", "--log", "--repo", "github.com/organisation/project"])
        #expect(GitHub.repositoryArguments(["pr", "view", "123", "--repo", "other/repo"], context: context)
            == ["pr", "view", "123", "--repo", "other/repo"])
    }
}

private actor ReadProbe {
    private(set) var count = 0
    private var released = false
    private var readers: [CheckedContinuation<Void, Never>] = []
    private var started: [CheckedContinuation<Void, Never>] = []

    func execute() async -> ShellResult {
        count += 1
        let waiting = started
        started.removeAll()
        for continuation in waiting { continuation.resume() }
        if !released { await withCheckedContinuation { readers.append($0) } }
        return ShellResult(status: 0, stdout: "answer", stderr: "")
    }

    func waitUntilStarted() async {
        if count > 0 { return }
        await withCheckedContinuation { started.append($0) }
    }

    func release() {
        released = true
        let waiting = readers
        readers.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}
