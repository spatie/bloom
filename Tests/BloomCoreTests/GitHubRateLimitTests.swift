import Foundation
import Testing
@testable import BloomCore

@Suite("GitHub rate limits")
struct GitHubRateLimitTests {
    @Test("an older success cannot clear a newer pause")
    func staleSuccess() async throws {
        let limits = GitHubRateLimits()
        let now = Date(timeIntervalSince1970: 1_000)
        let first = try await limits.check(host: "github.com", now: now)
        let concurrent = try await limits.check(host: "github.com", now: now)
        let retry = await limits.limited(host: "github.com", lease: first, retryAt: nil, now: now)
        await limits.succeeded(host: "github.com", lease: concurrent, now: now)
        #expect(retry == now.addingTimeInterval(30))
        await #expect(throws: GitHubReadFailure.self) { try await limits.check(host: "github.com", now: now) }
        let other = try await limits.check(host: "github.example.com", now: now)
        #expect(other == 0)
    }

    @Test("explicit operations do not clear the background cooldown")
    func interactiveLease() async throws {
        let limits = GitHubRateLimits()
        let now = Date(timeIntervalSince1970: 1_000)
        let lease = try await limits.check(host: "GITHUB.COM", now: now)
        await limits.limited(host: "github.com", lease: lease, retryAt: now.addingTimeInterval(120), now: now)
        let interactive = try await limits.check(host: "github.com", interactive: true, now: now)
        await limits.succeeded(host: "github.com", lease: interactive, now: now)
        await #expect(throws: GitHubReadFailure.self) { try await limits.check(host: "github.com", now: now) }
        let after = try await limits.check(host: "github.com", now: now.addingTimeInterval(121))
        await limits.succeeded(host: "github.com", lease: after, now: now.addingTimeInterval(121))
        let next = await limits.limited(host: "github.com", lease: after, retryAt: nil, now: now.addingTimeInterval(121))
        #expect(next == now.addingTimeInterval(151))
    }

    @Test("reset headers are parsed without confusing missing PRs with throttling")
    func headers() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(GitHubReadFailure.retryDate(from: "Retry-After: 120", now: now) == now.addingTimeInterval(120))
        #expect(GitHubReadFailure.retryDate(from: "X-RateLimit-Reset: 1200", now: now) == Date(timeIntervalSince1970: 1_200))
        #expect(GitHubReadFailure.retryDate(from: "Retry-After: later", now: now) == nil)
        #expect(GitHubReadFailure.isRateLimit("API rate limit exceeded"))
        #expect(!GitHubReadFailure.isRateLimit("no pull requests found"))
    }

    @Test("fork lookups identify the base repo and the publication owner")
    func forkArguments() {
        let context = GitRepositoryContext.resolve(config: [
            "remote.origin.url": "git@github.com:fork/project.git",
            "remote.upstream.url": "https://github.com/upstream/project.git",
            "branch.main.remote": "upstream", "remote.pushdefault": "origin",
        ], base: "main", branch: "feature")
        #expect(GitHub.repositoryArguments(["pr", "view", "feature", "--json", "number"], context: context)
            == ["pr", "view", "fork:feature", "--json", "number", "--repo", "github.com/upstream/project"])
        #expect(GitHub.repositoryArguments(["pr", "view", "123"], context: context)
            == ["pr", "view", "123", "--repo", "github.com/upstream/project"])
    }
}
