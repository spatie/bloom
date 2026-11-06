import Foundation
import Testing
@testable import BloomCore

/// How a remote becomes the host and repository `gh` is pointed at, as the code does it today,
/// accidents included (a two segment gitlab.com remote is handed to gh).
@Suite("GitHub repository resolution")
struct GitHubRepositoryResolutionTests {
    @Test("the host of a remote", arguments: [
        (remote: "https://github.com/acme/app.git", host: "github.com"),
        (remote: "https://GitHub.com/acme/app", host: "github.com"),
        (remote: "git@github.com:acme/app.git", host: "github.com"),
        (remote: "ssh://git@github.com/acme/app.git", host: "github.com"),
        (remote: "git@GHE.corp.example:acme/app.git", host: "ghe.corp.example"),
        (remote: "git@gitlab.com:group/subgroup/app.git", host: "gitlab.com"),
        (remote: "https://gitlab.example.com/group/subgroup/app.git", host: "gitlab.example.com"),
    ])
    func host(remote: String, host: String) {
        #expect(GitHub.repositoryHost(remote) == host)
    }

    @Test("a remote with no host has none", arguments: ["/Users/someone/project", "../project"])
    func noHost(remote: String) {
        #expect(GitHub.repositoryHost(remote) == nil)
    }

    @Test("no remote has no host")
    func missingRemote() {
        #expect(GitHub.repositoryHost(nil) == nil)
    }

    @Test("the repository gh is told to use", arguments: [
        (remote: "https://github.com/acme/app.git", specifier: "github.com/acme/app"),
        (remote: "https://github.com/acme/app", specifier: "github.com/acme/app"),
        (remote: "https://github.com/acme/app/", specifier: "github.com/acme/app"),
        (remote: "git@github.com:acme/app.git", specifier: "github.com/acme/app"),
        (remote: "ssh://git@github.com/acme/app.git", specifier: "github.com/acme/app"),
        (remote: "git@ghe.corp.example:acme/app.git", specifier: "ghe.corp.example/acme/app"),
        (remote: "git@gitlab.com:group/app.git", specifier: "gitlab.com/group/app"),
    ])
    func specifier(remote: String, specifier: String) {
        #expect(GitHub.repositorySpecifier(remote) == specifier)
    }

    @Test("a remote that is not two segments on a host names no repository", arguments: [
        "git@gitlab.com:group/subgroup/app.git",
        "https://gitlab.example.com/group/subgroup/app.git",
        "https://github.com/acme",
        "https://github.com/-acme/app",
        "/Users/someone/project",
    ])
    func noSpecifier(remote: String) {
        #expect(GitHub.repositorySpecifier(remote) == nil)
    }

    @Test("the host a request is rate limited under", arguments: [
        (arguments: ["pr", "view", "1", "--repo", "ghe.corp.example/acme/app"], host: "ghe.corp.example"),
        (arguments: ["pr", "view", "1", "--repo=ghe.corp.example/acme/app"], host: "ghe.corp.example"),
        (arguments: ["pr", "view", "1", "-Rghe.corp.example/acme/app"], host: "ghe.corp.example"),
        (arguments: ["pr", "ready", "https://GHE.corp.example/acme/app/pull/1"], host: "ghe.corp.example"),
    ])
    func requestHost(arguments: [String], host: String) {
        #expect(GitHub.requestHost(arguments: arguments, context: nil) == host)
    }

    @Test("a request with no host of its own takes the base remote's")
    func requestHostFromContext() {
        let context = GitRepositoryContext.resolve(config: [
            "remote.origin.url": "git@ghe.corp.example:acme/app.git",
            "branch.main.remote": "origin",
        ], base: "main", branch: "feature")
        #expect(GitHub.requestHost(arguments: ["pr", "view", "feature"], context: context) == "ghe.corp.example")
        #expect(GitHub.requestHost(arguments: ["pr", "view", "1", "--repo", "acme/app"], context: context)
            == "ghe.corp.example")
    }

    @Test("a request with no host anywhere falls back to GH_HOST, then github.com")
    func requestHostFallback() {
        let expected = ProcessInfo.processInfo.environment["GH_HOST"] ?? "github.com"
        #expect(GitHub.requestHost(arguments: ["pr", "list"], context: nil) == expected)
    }

    @Test("a pull request created from a fork names its head in the fork")
    func forkCreate() {
        let context = GitRepositoryContext.resolve(config: [
            "remote.origin.url": "git@github.com:fork/project.git",
            "remote.upstream.url": "https://github.com/upstream/project.git",
            "branch.main.remote": "upstream", "remote.pushdefault": "origin",
        ], base: "main", branch: "feature")
        #expect(GitHub.repositoryArguments(
            ["pr", "create", "--base", "main", "--title", "Title", "--body", "Body"], context: context
        ) == [
            "pr", "create", "--base", "main", "--title", "Title", "--body", "Body",
            "--head", "fork:feature", "--repo", "github.com/upstream/project",
        ])
    }

    @Test("a pull request created in its own repository names no head")
    func ownCreate() {
        let context = GitRepositoryContext.resolve(config: [
            "remote.origin.url": "git@github.com:acme/app.git",
            "branch.main.remote": "origin",
        ], base: "main", branch: "feature")
        #expect(GitHub.repositoryArguments(["pr", "create", "--base", "main", "--draft"], context: context)
            == ["pr", "create", "--base", "main", "--draft", "--repo", "github.com/acme/app"])
    }

    @Test("commands outside pull requests and run logs are left alone", arguments: [
        ["api", "user", "--jq", ".login"],
        ["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"],
        ["run", "list"],
        ["auth", "status"],
    ])
    func untouchedFamilies(arguments: [String]) {
        let context = GitRepositoryContext.resolve(config: [
            "remote.origin.url": "git@github.com:acme/app.git",
            "branch.main.remote": "origin",
        ], base: "main", branch: "feature")
        #expect(GitHub.repositoryArguments(arguments, context: context) == arguments)
    }

    @Test("a remote that names no repository adds no --repo")
    func subgroupRemote() {
        let context = GitRepositoryContext.resolve(config: [
            "remote.origin.url": "git@gitlab.com:group/subgroup/app.git",
            "branch.main.remote": "origin",
        ], base: "main", branch: "feature")
        #expect(GitHub.repositoryArguments(["pr", "view", "1"], context: context) == ["pr", "view", "1"])
    }
}
