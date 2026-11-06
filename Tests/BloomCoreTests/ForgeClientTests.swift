import Foundation
import Testing
@testable import BloomCore

@Suite("Forge client", .scratchDirectory)
struct ForgeClientTests {
    @Test("a directory that is not a repository is asked through GitHub")
    func resolvesGitHub() async {
        let client = await ForgeResolver.client(for: TestScratch.unique("forge"))
        #expect(ObjectIdentifier(client) == ObjectIdentifier(GitHubForge.self))
    }

    @Test("a GitLab job's page is never handed to gh")
    func gitLabJobOnGitHub() async {
        let target = CheckFailureHandoff.LogTarget(runID: "1", jobID: "1", project: "group/app")
        await #expect(throws: GitHubError.self) {
            try await GitHub.$commandOverride.withValue({ _, _ in
                Issue.record("gh should not be asked for a GitLab job")
                return ShellResult(status: 0, stdout: "log", stderr: "")
            }) {
                try await GitHubForge.checkRunLog(target, worktree: TestScratch.unique("forge-log"))
            }
        }
    }

    @Test("the GitHub client runs the gh command GitHub runs")
    func forwards() async throws {
        let worktree = TestScratch.unique("forge-forward")
        let asked = ArgumentLog()
        let client = await ForgeResolver.client(for: worktree)
        _ = try await GitHub.$commandOverride.withValue({ arguments, _ in
            await asked.record(arguments)
            return ShellResult(status: 0, stdout: #"{"number":1,"headRefName":"feature"}"#, stderr: "")
        }) {
            try await client.pullRequest(forBranch: "feature", worktree: worktree)
        }
        #expect(await asked.first.map { Array($0.prefix(3)) } == ["pr", "view", "feature"])
    }
}

private actor ArgumentLog {
    private(set) var first: [String]?

    func record(_ arguments: [String]) {
        if first == nil { first = arguments }
    }
}
