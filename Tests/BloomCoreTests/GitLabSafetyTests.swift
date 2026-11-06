import Foundation
import Testing
@testable import BloomCore

@Suite("GitLab request identity", .tags(.git), .scratchDirectory)
struct GitLabSafetyTests {
    @Test("Continue accepts only a fork alias recorded for the exact GitLab MR", arguments: [
        (Forge.gitLab, "https://gitlab.com/group/app/-/merge_requests/42", true),
        (Forge.gitLab, "https://gitlab.com/other/app/-/merge_requests/42", false),
        (Forge.gitHub, "https://github.com/group/app/pull/42", false),
    ])
    func continueForkAlias(forge: Forge, url: String, allowsAlias: Bool) async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try await Git.check(["remote", "add", "origin", "https://gitlab.com/group/app.git"], in: repo.path)
        try await Git.check(["checkout", "-qb", "contributor-feature"], in: repo.path)
        try await Git.check([
            "config", "branch.contributor-feature.bloom-merge-request",
            "https://gitlab.com/group/app/-/merge_requests/42",
        ], in: repo.path)
        let workspace = Workspace(repoID: RepoID("r"), name: "fork", branch: "contributor-feature", path: repo.path, baseBranch: "main")
        let request = PullRequest(number: 42, title: "", url: url, state: "MERGED", branch: "feature", baseBranch: "main", forge: forge)
        let manager = WorkspaceManager(store: try Store.inMemory())
        let facts = try await manager.continuationFacts(workspace: workspace, pullRequest: request, isAgentRunning: false)
        let decision = ContinuationGate.decide(facts)
        if allowsAlias {
            #expect(decision == .cut(branch: "contributor-feature-2"))
        } else {
            #expect(decision.refusal == .switchedByHand(onBranch: "contributor-feature", pullRequestBranch: "feature"))
        }
    }

    @Test("the owner's project checkout never reads or directly creates a GitLab request")
    func projectCheckoutHasNoRequests() async throws {
        let workspace = Workspace(
            repoID: RepoID("r"), name: "project", branch: "main", path: "/nowhere", baseBranch: "main",
            pullRequestNumber: 42, kind: .projectCheckout
        )
        try await GitLab.$commandOverride.withValue({ _, _ in
            Issue.record("The project checkout reached glab")
            return ShellResult(status: 0, stdout: "", stderr: "")
        }) {
            let request = try await GitLab.pullRequest(for: workspace, maxAge: .zero)
            #expect(request == nil)
            await #expect(throws: GitHubError.self) {
                try await DirectPullRequestCreation.create(for: workspace, forge: .gitLab)
            }
        }
    }

    @Test("the stored fork MR outranks a same-project MR with the same branch, including workspace_merge")
    func forkIdentity() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try await Git.check(["remote", "add", "origin", "https://gitlab.com/group/app.git"], in: repo.path)
        try await Git.check(["checkout", "-qb", "feature"], in: repo.path)
        let workspace = Workspace(repoID: RepoID("r"), name: "fork", branch: "feature", path: repo.path, baseBranch: "main", pullRequestNumber: 100)
        let detail = #"{"iid":100,"state":"opened","source_branch":"feature","target_branch":"main","source_project_id":2,"target_project_id":1,"web_url":"https://gitlab.com/group/app/-/merge_requests/100"}"#
        await GitLab.$commandOverride.withValue({ arguments, _ in
            if arguments.last?.contains("source_branch=") == true {
                return ShellResult(status: 0, stdout: #"[{"iid":99,"state":"opened","source_project_id":1,"target_project_id":1}]"#, stderr: "")
            }
            return ShellResult(status: 0, stdout: detail, stderr: "")
        }) {
            do {
                let found = try await GitLab.pullRequest(for: workspace, maxAge: .zero)
                #expect(found?.number == 100)
                let reading = await WorkspaceMergeTool.ask(workspace)
                guard case .found(let request, _) = reading else {
                    Issue.record("workspace_merge lost the fork MR")
                    return
                }
                #expect(request.number == 100)
            } catch { Issue.record("The fork lookup failed: \(error)") }
        }
    }

    @Test("ready refuses another forge or project before invoking glab", arguments: [Forge.gitHub, .gitLab])
    func readyIdentity(forge: Forge) async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try await Git.check(["remote", "add", "origin", "https://gitlab.com/group/app.git"], in: repo.path)
        let draft = PullRequest(number: 42, title: "", url: "https://other.example/group/app/-/merge_requests/42", state: "OPEN", isDraft: true, forge: forge)
        await #expect(throws: GitHubError.self) {
            try await GitLab.$commandOverride.withValue({ _, _ in
                Issue.record("An unrelated draft was mutated")
                return ShellResult(status: 0, stdout: "", stderr: "")
            }) { try await GitLab.markReadyForReview(draft, worktree: repo.path) }
        }
    }

    @Test("rebase names the selected project and a fork's source branch rather than its local alias")
    func rebaseSource() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try await Git.check(["remote", "add", "origin", "https://github.com/group/app.git"], in: repo.path)
        try await Git.check(["remote", "add", "gitlab", "https://gitlab.com/group/app.git"], in: repo.path)
        try await Git.check(["checkout", "-qb", "contributor-feature"], in: repo.path)
        try await Git.check(["config", "branch.contributor-feature.remote", "https://gitlab.com/contributor/app.git"], in: repo.path)
        try await Git.check(["config", "branch.contributor-feature.merge", "refs/heads/feature"], in: repo.path)
        let request = PullRequest(number: 42, title: "", url: "https://gitlab.com/group/app/-/merge_requests/42", state: "OPEN", branch: "feature", baseBranch: "main", forge: .gitLab)
        let prompt = try await GitLab.rebasePrompt(request, worktree: repo.path)
        #expect(prompt.contains("'-R' 'https://gitlab.com/group/app'"))
        #expect(prompt.contains("'--' 'https://gitlab.com/contributor/app.git' 'refs/heads/feature'"))
        #expect(!prompt.contains("origin"))
        #expect(!prompt.contains("contributor-feature"))
    }

    @Test("MR URLs on another host never resolve as this project's number", arguments: [
        "https://gitlab.com/group/app/-/merge_requests/42",
        "https://github.com/group/app/pull/42",
    ])
    func referenceHost(_ text: String) {
        #expect(WorkspaceCheckoutResolver.problem(with: text, in: "group/app", forge: .gitLab, host: "gitlab.internal") != nil)
        #expect(WorkspaceCheckoutResolver.problem(with: "!42", in: "group/app", forge: .gitLab, host: "gitlab.internal") == nil)
    }

    @Test("non-squash methods cannot silently retain an MR's squash setting")
    func squashPolicy() throws {
        let payload = try GitLabDecoding.mergeRequest(from: Data(#"{"iid":42,"squash":false,"squash_on_merge":true}"#.utf8))
        let request = GitLabDecoding.pullRequest(payload, runs: [])
        #expect(request.mergeMethodProblem(.merge) != nil)
        #expect(request.mergeMethodProblem(.rebase) != nil)
        #expect(request.mergeMethodProblem(.squash) == nil)
        #expect(GitHub.MergeMethod.merge.label(on: .gitLab) == "Project merge method")
        #expect(GitHub.MergeMethod.merge.phrase(on: .gitHub) == "merge commit")
    }

    @Test("signing in invalidates a previously refused self-hosted remote")
    func signInInvalidatesRouting() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        let host = "gitlab-auth-\(UUID().uuidString).example"
        try await Git.check(["remote", "add", "origin", "https://\(host)/group/app.git"], in: repo.path)
        let before = await GitLab.$commandOverride.withValue({ _, _ in ShellResult(status: 1, stdout: "", stderr: "signed out") }) {
            await ForgeResolver.forge(for: repo.path)
        }
        #expect(before == .gitHub)
        await ForgeResolver.invalidateAuthentication()
        let after = await GitLab.$commandOverride.withValue({ _, _ in ShellResult(status: 0, stdout: "", stderr: "") }) {
            await ForgeResolver.forge(for: repo.path)
        }
        #expect(after == .gitLab)
    }

    @Test("installing glab settles a cached self-hosted fallback without a repository edit")
    func installationInvalidatesRouting() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        let host = "gitlab-install-\(UUID().uuidString).example"
        try await Git.check(["remote", "add", "origin", "https://\(host)/group/app.git"], in: repo.path)
        let before = await GitLab.$installedOverride.withValue(false) { await ForgeResolver.forge(for: repo.path) }
        #expect(before == .gitHub)
        let after = await GitLab.$commandOverride.withValue({ _, _ in ShellResult(status: 0, stdout: "", stderr: "") }) {
            await ForgeResolver.forge(for: repo.path)
        }
        #expect(after == .gitLab)
    }
}
