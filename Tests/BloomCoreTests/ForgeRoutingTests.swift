import Foundation
import Testing
@testable import BloomCore

@Suite("Forge routing", .scratchDirectory)
struct ForgeRoutingTests {
    private static let cases: [(declared: Forge?, base: String?, remotes: [String], decision: ForgeRouting.Decision)] = [
        (nil, "git@github.com:acme/app.git", [], .forge(.gitHub)),
        (nil, "git@gitlab.com:group/app.git", ["git@github.com:acme/app.git"], .forge(.gitHub)),
        (nil, "git@gitlab.com:group/sub/app.git", [], .forge(.gitLab)),
        (nil, "https://gitlab.example.com/group/app.git", [], .askGlab(host: "gitlab.example.com")),
        (nil, "git@ghe.corp.example:acme/app.git", [], .askGlab(host: "ghe.corp.example")),
        (nil, "git@github-work:acme/app.git", [], .forge(.gitHub)),
        (nil, "https://github.corp.example/acme/app.git", [], .forge(.gitHub)),
        (nil, nil, [], .forge(.gitHub)),
        (.gitLab, "git@github.com:acme/app.git", [], .forge(.gitLab)),
        (.gitHub, "git@gitlab.com:group/app.git", [], .forge(.gitHub)),
    ]

    @Test("GitLab only on positive evidence, GitHub everywhere else", arguments: cases)
    func decide(declared: Forge?, base: String?, remotes: [String], decision: ForgeRouting.Decision) {
        #expect(ForgeRouting.decide(declared: declared, baseRemoteURL: base, remoteURLs: remotes) == decision)
    }

    @Test("a host glab is not signed in to stays on GitHub")
    func unsignedHost() async {
        let host = "gitlab-\(UUID().uuidString).example"
        let signedIn = await GitLab.$commandOverride.withValue({ _, _ in
            ShellResult(status: 1, stdout: "", stderr: "not logged in")
        }) {
            await GlabSignIn.shared.isSignedIn(to: host)
        }
        #expect(signedIn == false)
    }

    @Test("a host glab is signed in to is GitLab's")
    func signedHost() async {
        let host = "gitlab-\(UUID().uuidString).example"
        let signedIn = await GitLab.$commandOverride.withValue({ arguments, _ in
            ShellResult(status: arguments == ["auth", "status", "--hostname", host] ? 0 : 1, stdout: "", stderr: "")
        }) {
            await GlabSignIn.shared.isSignedIn(to: host)
        }
        #expect(signedIn)
    }

    @Test("a repository resolves from its remotes, and again when they change", .tags(.git))
    func resolvesRepository() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try await Shell.check("git", ["remote", "add", "origin", "git@gitlab.com:group/sub/app.git"], cwd: repo.path)
        #expect(await ForgeResolver.forge(for: repo.path) == .gitLab)

        try await Shell.check("git", ["remote", "add", "mirror", "git@github.com:acme/app.git"], cwd: repo.path)
        #expect(await ForgeResolver.forge(for: repo.path) == .gitHub)

        try repo.write(".bloom/settings.toml", "[git]\nforge = \"gitlab\"\n")
        #expect(await ForgeResolver.forge(for: repo.path) == .gitLab)
    }

    @Test("only hosts beside a GitHub remote can make a repository ambiguous", arguments: [
        (hosts: ["github.com", "gitlab.com"], others: Set(["gitlab.com"])),
        (hosts: ["github-work", "git.example.fr"], others: Set(["git.example.fr"])),
        (hosts: ["gitlab.com", "git.example.fr"], others: Set<String>()),
        (hosts: ["github.com"], others: Set<String>()),
    ])
    func hostsBesideGitHub(hosts: [String], others: Set<String>) {
        #expect(ForgeRouting.hostsBesideGitHub(hosts) == others)
    }

    @Test("a repository on both forges asks once, and the answer stays on this machine", .tags(.git))
    func choice() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try await Shell.check("git", ["remote", "add", "origin", "git@gitlab.com:group/app.git"], cwd: repo.path)
        try await Shell.check("git", ["remote", "add", "mirror", "git@github.com:acme/app.git"], cwd: repo.path)
        let glabInstalled: @Sendable ([String], String?) async throws -> ShellResult = { _, _ in ShellResult(status: 1, stdout: "", stderr: "") }
        let asked = await GitLab.$commandOverride.withValue(glabInstalled) { await ForgeResolver.offersBoth(repo.path) }
        #expect(asked)
        #expect(await ForgeResolver.forge(for: repo.path) == .gitHub)

        try ForgeResolver.remember(.gitLab, for: repo.path)
        #expect(await ForgeResolver.forge(for: repo.path) == .gitLab)
        let askedAgain = await GitLab.$commandOverride.withValue(glabInstalled) { await ForgeResolver.offersBoth(repo.path) }
        #expect(askedAgain == false)
        #expect(FileManager.default.fileExists(atPath: "\(repo.path)/.bloom/settings.local.toml"))
        #expect(FileManager.default.fileExists(atPath: "\(repo.path)/.bloom/settings.toml") == false)
    }

    @Test("remote addresses are read from git's config file without git")
    func remoteURLs() {
        let config = "[remote \"origin\"]\n\turl = git@github.com:acme/app.git\n\tpushurl = x\n[remote \"up\"]\n\turl=\"https://gitlab.com/g/a\"\n"
        #expect(ForgeResolver.remoteURLs(in: config) == ["git@github.com:acme/app.git", "https://gitlab.com/g/a"])
    }

    @Test("a project's settings can name its forge")
    func declared() throws {
        let repo = TestScratch.unique("forge-settings")
        try FileManager.default.createDirectory(atPath: "\(repo)/.bloom", withIntermediateDirectories: true)
        try "[git]\nforge = \"gitlab\"\n".write(toFile: "\(repo)/.bloom/settings.toml", atomically: true, encoding: .utf8)
        #expect(SettingsLoader.load(repo: repo).forge == .gitLab)
    }

    @Test("a GitLab remote names its whole namespace", arguments: [
        (remote: "git@gitlab.com:group/sub/app.git", host: "gitlab.com", path: "group/sub/app", apiID: "group%2Fsub%2Fapp"),
        (remote: "https://gitlab.example.com/group/app", host: "gitlab.example.com", path: "group/app", apiID: "group%2Fapp"),
        (remote: "ssh://git@gitlab.example.com:2222/group/app.git", host: "gitlab.example.com", path: "group/app", apiID: "group%2Fapp"),
    ])
    func project(remote: String, host: String, path: String, apiID: String) throws {
        let project = try #require(GitLabProject(remote: remote))
        #expect(project.host == host)
        #expect(project.path == path)
        #expect(project.apiID == apiID)
        #expect(project.webURL == "https://\(host)/\(path)")
    }

    @Test("a remote with one segment is no project")
    func noProject() {
        #expect(GitLabProject(remote: "https://gitlab.com/group") == nil)
        #expect(GitLabProject(remote: nil) == nil)
    }
}
