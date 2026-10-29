import Foundation
import Testing
@testable import BloomCore

@Suite("Direct GitLab create and merge", .tags(.git), .scratchDirectory)
struct GitLabDirectTests {
    private let project = "https://gitlab.com/group/app"

    @Test("merges the confirmed head with no auto-merge, the method's flag and the project named")
    func mergesTheConfirmedHead() async throws {
        let repo = try await featureRepo()
        defer { repo.cleanUp() }
        let head = try await Git.headSHA(of: repo.path)

        for method in [GitHub.MergeMethod.squash, .merge] {
            let glab = MergeGlab(head: head)
            let outcome = try await GitLab.$commandOverride.withValue({ arguments, _ in
                await glab.execute(arguments)
            }) {
                try await GitLab.mergePullRequest(expected(head: head), into: "main", method: method, worktree: repo.path)
            }
            let flags: [String] = method == .squash ? ["--squash"] : []
            let merge = ["mr", "merge", "42", "--yes", "--auto-merge=false", "--sha", head] + flags + ["-R", project]
            #expect(outcome == .merged)
            #expect(await glab.merges == [merge])
        }
    }

    @Test("a rebase runs first, and the rebased head is what gets merged")
    func rebasesThenMerges() async throws {
        let repo = try await featureRepo()
        defer { repo.cleanUp() }
        let head = try await Git.headSHA(of: repo.path)
        let rebased = try await rebasedOnServer(repo, writing: "a\n")
        let glab = MergeGlab(head: head, rebasedHead: rebased)

        let outcome = try await GitLab.$commandOverride.withValue({ arguments, _ in
            await glab.execute(arguments)
        }) {
            try await GitLab.mergePullRequest(expected(head: head), into: "main", method: .rebase, worktree: repo.path)
        }

        #expect(outcome == .merged)
        #expect(await glab.rebases == 1)
        #expect(await glab.merges == [
            ["mr", "merge", "42", "--yes", "--auto-merge=false", "--sha", rebased, "-R", project],
        ])
    }

    @Test("a rebase onto a target that changed a line beside a confirmed change is still merged")
    func rebaseBesideATargetChange() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try await git(repo, "remote", "add", "origin", "git@gitlab.com:group/app.git")
        try repo.write("f.txt", (1...10).map(String.init).joined(separator: "\n") + "\n")
        try await git(repo, "add", "f.txt")
        try await git(repo, "commit", "-q", "-m", "Count")
        try await git(repo, "update-ref", "refs/remotes/origin/main", "HEAD")
        try await git(repo, "checkout", "-q", "-b", "feature")
        try await replace("3", with: "three", in: repo)
        let head = try await Git.headSHA(of: repo.path)
        _ = try await server(for: "git@gitlab.com:group/app.git", in: repo)
        // Two lines from the confirmed change: a patch id counts it as context and differs.
        try await git(repo, "checkout", "-q", "-b", "rebased", "main")
        try await replace("5", with: "five", in: repo)
        try await git(repo, "cherry-pick", head)
        let rebased = try await Git.headSHA(of: repo.path)
        try await git(repo, "push", "-q", "origin", "rebased:refs/merge-requests/42/head")
        try await git(repo, "checkout", "-q", "feature")
        let glab = MergeGlab(head: head, rebasedHead: rebased)

        let outcome = try await GitLab.$commandOverride.withValue({ arguments, _ in
            await glab.execute(arguments)
        }) {
            try await GitLab.mergePullRequest(expected(head: head), into: "main", method: .rebase, worktree: repo.path)
        }

        #expect(outcome == .merged)
        #expect(await glab.merges.first?.contains(rebased) == true)
    }

    @Test("a merge request already on its target, which the rebase leaves alone, merges at the confirmed head")
    func rebaseThatChangesNothing() async throws {
        let repo = try await featureRepo()
        defer { repo.cleanUp() }
        let head = try await Git.headSHA(of: repo.path)
        let glab = MergeGlab(head: head)

        let outcome = try await GitLab.$commandOverride.withValue({ arguments, _ in
            await glab.execute(arguments)
        }) {
            try await GitLab.mergePullRequest(expected(head: head), into: "main", method: .rebase, worktree: repo.path)
        }

        #expect(outcome == .merged)
        #expect(await glab.merges == [
            ["mr", "merge", "42", "--yes", "--auto-merge=false", "--sha", head, "-R", project],
        ])
    }

    @Test("a rebase whose commits have the confirmed titles but other contents is not merged")
    func refusesOtherContents() async throws {
        let repo = try await featureRepo()
        defer { repo.cleanUp() }
        let head = try await Git.headSHA(of: repo.path)
        // A push between the confirmation and the rebase: the same title, a different change.
        let rebased = try await rebasedOnServer(repo, writing: "not what was confirmed\n")
        let glab = MergeGlab(head: head, rebasedHead: rebased)

        do {
            _ = try await GitLab.$commandOverride.withValue({ arguments, _ in
                await glab.execute(arguments)
            }) {
                try await GitLab.mergePullRequest(expected(head: head), into: "main", method: .rebase, worktree: repo.path)
            }
            Issue.record("A rebase with unconfirmed contents was merged")
        } catch let error as GitHubError {
            #expect(error.message.contains("not the ones confirmed"))
        }
        #expect(await glab.merges.isEmpty)
    }

    @Test("a rebase that brought in a commit nobody confirmed is not merged")
    func refusesAnUnconfirmedCommit() async throws {
        let repo = try await featureRepo()
        defer { repo.cleanUp() }
        let head = try await Git.headSHA(of: repo.path)
        let glab = MergeGlab(head: head, rebasedHead: String(repeating: "b", count: 40), extraAfterRebase: "Sneaked in")

        do {
            _ = try await GitLab.$commandOverride.withValue({ arguments, _ in
                await glab.execute(arguments)
            }) {
                try await GitLab.mergePullRequest(expected(head: head), into: "main", method: .rebase, worktree: repo.path)
            }
            Issue.record("A rebase with an unconfirmed commit was merged")
        } catch let error as GitHubError {
            #expect(error.message.contains("not the ones confirmed"))
        }
        #expect(await glab.merges.isEmpty)
    }

    @Test("a newly pushed head refuses the direct merge before glab merges")
    func refusesChangedHead() async throws {
        let repo = try await featureRepo()
        defer { repo.cleanUp() }
        let head = try await Git.headSHA(of: repo.path)
        let glab = MergeGlab(head: String(repeating: "a", count: 40))

        do {
            _ = try await GitLab.$commandOverride.withValue({ arguments, _ in
                await glab.execute(arguments)
            }) {
                try await GitLab.mergePullRequest(expected(head: head), into: "main", method: .merge, worktree: repo.path)
            }
            Issue.record("A changed merge request head was merged")
        } catch let error as GitHubError {
            #expect(error.message == "The merge request changed since it was shown. Refresh it before merging.")
        }
        #expect(await glab.merges.isEmpty)
    }

    @Test("opens the merge request from the pushed branch, described by its commits as gh --fill does")
    func createsFromCommits() async throws {
        let repo = try await featureRepo()
        defer { repo.cleanUp() }
        try repo.write("b.txt", "b\n")
        try await Shell.check("git", ["add", "b.txt"], cwd: repo.path)
        try await Shell.check("git", ["commit", "-q", "-m", "Add b"], cwd: repo.path)
        let head = try await Git.headSHA(of: repo.path)
        let glab = MergeGlab(head: head)

        let created = try await GitLab.$commandOverride.withValue({ arguments, _ in
            await glab.execute(arguments)
        }) {
            try await GitLab.createPullRequestFromCommits(worktree: repo.path, base: "main", title: "Feature")
        }

        #expect(created.number == 42)
        #expect(created.forge == .gitLab)
        #expect(await glab.creates == [[
            "mr", "create", "--source-branch", "feature", "--target-branch", "main",
            "--title", "Feature", "--description", "- Add a\n- Add b", "--yes", "-R", project,
        ]])
    }

    @Test("beside a GitHub origin, the branch is pushed to the GitLab remote and the request names no fork")
    func pushesToTheGitLabRemote() async throws {
        let repo = try await featureRepo()
        defer { repo.cleanUp() }
        try await git(repo, "remote", "rename", "origin", "gitlab")
        try await git(repo, "remote", "add", "origin", "git@github.com:group/app.git")
        try await git(repo, "update-ref", "refs/remotes/origin/main", "refs/remotes/gitlab/main")
        let gitLab = try await server(for: "git@gitlab.com:group/app.git", in: repo)
        let gitHub = try await server(for: "git@github.com:group/app.git", in: repo)
        let head = try await Git.headSHA(of: repo.path)
        let glab = MergeGlab(head: head)
        let workspace = Workspace(repoID: RepoID("r"), name: "Feature", branch: "feature", path: repo.path, baseBranch: "main")

        let created = try await GitLab.$commandOverride.withValue({ arguments, _ in
            if arguments.last?.contains("source_branch=") == true { return ShellResult(status: 0, stdout: "[]", stderr: "") }
            return await glab.execute(arguments)
        }) {
            try await DirectPullRequestCreation.create(for: workspace, forge: .gitLab)
        }

        #expect(created.number == 42)
        #expect(await Git.revision(of: "refs/heads/feature", in: gitLab) == head)
        #expect(await Git.revision(of: "refs/heads/feature", in: gitHub) == nil)
        #expect(await glab.creates == [[
            "mr", "create", "--source-branch", "feature", "--target-branch", "main",
            "--title", "Feature", "--description", "Why a", "--yes", "-R", project,
        ]])
    }

    @Test("a single commit's body is the description, and glab's printed URL names the request")
    func descriptionAndNumber() {
        #expect(GitLab.description(fromCommits: [(subject: "Add a", body: "Why a\n")]) == "Why a")
        #expect(GitLab.description(fromCommits: []) == "")
        #expect(GitLab.commits(fromLog: "Add a\u{1f}Why\n\u{1e}\nAdd b\u{1f}\u{1e}\n").map { $0.subject } == ["Add a", "Add b"])
        #expect(GitLab.mergeRequestNumber(in: "Creating…\nhttps://gitlab.com/g/app/-/merge_requests/42\n") == 42)
        #expect(GitLab.mergeRequestNumber(in: "nothing here") == nil)
    }

    @Test("GitHub's words for the direct routes are the ones it had")
    func gitHubWords() {
        #expect(Forge.gitHub.command("merge") == "gh pr merge")
        #expect(Forge.gitHub.titledRequest == "Pull request")
        #expect(Forge.gitHub.shortRequest == "PR")
        #expect(Forge.gitLab.command("merge") == "glab mr merge")
        #expect(MergeExecution.direct.label(on: .gitLab) == "Merge with GitLab CLI")
    }

    /// On `feature`, one commit ahead of `main`, with `origin/main` where `main` is.
    private func featureRepo() async throws -> TempRepo {
        let repo = try await TempRepo()
        try await Shell.check("git", ["remote", "add", "origin", "git@gitlab.com:group/app.git"], cwd: repo.path)
        try await Shell.check("git", ["update-ref", "refs/remotes/origin/main", "HEAD"], cwd: repo.path)
        try await Shell.check("git", ["checkout", "-q", "-b", "feature"], cwd: repo.path)
        try repo.write("a.txt", "a\n")
        try await Shell.check("git", ["add", "a.txt"], cwd: repo.path)
        try await Shell.check("git", ["commit", "-q", "-m", "Add a", "-m", "Why a"], cwd: repo.path)
        return repo
    }

    /// A bare repository standing in for the server at `url`, which git in `repo` is sent to instead.
    private func server(for url: String, in repo: TempRepo) async throws -> String {
        let server = TestScratch.unique("server")
        try await Shell.check("git", ["init", "-q", "--bare", server], cwd: repo.path)
        try await git(repo, "config", "url.\(server).insteadOf", url)
        return server
    }

    /// What GitLab's rebase leaves on the server: `main` moved on by a commit, and `feature`'s one
    /// commit, titled as confirmed and writing `contents` to `a.txt`, on top of it as the head of !42.
    private func rebasedOnServer(_ repo: TempRepo, writing contents: String) async throws -> String {
        _ = try await server(for: "git@gitlab.com:group/app.git", in: repo)
        try await git(repo, "checkout", "-q", "-b", "rebased", "main")
        try repo.write("m.txt", "m\n")
        try await git(repo, "add", "m.txt")
        try await git(repo, "commit", "-q", "-m", "Move main")
        try repo.write("a.txt", contents)
        try await git(repo, "add", "a.txt")
        try await git(repo, "commit", "-q", "-m", "Add a")
        let rebased = try await Git.headSHA(of: repo.path)
        try await git(repo, "push", "-q", "origin", "rebased:refs/merge-requests/42/head")
        try await git(repo, "checkout", "-q", "feature")
        try await git(repo, "branch", "-q", "-D", "rebased")
        return rebased
    }

    /// Rewrites one line of `f.txt` and commits it, titled after the line.
    private func replace(_ line: String, with text: String, in repo: TempRepo) async throws {
        let lines = (repo.read("f.txt") ?? "").components(separatedBy: "\n").map { $0 == line ? text : $0 }
        try repo.write("f.txt", lines.joined(separator: "\n"))
        try await git(repo, "commit", "-q", "-am", "Change \(line)")
    }

    private func git(_ repo: TempRepo, _ arguments: String...) async throws {
        try await Shell.check("git", arguments, cwd: repo.path)
    }

    private func expected(head: String) -> PullRequest {
        PullRequest(
            number: 42, title: "Feature", url: "\(project)/-/merge_requests/42", state: "OPEN",
            branch: "feature", baseBranch: "main", headRevision: head, forge: .gitLab
        )
    }
}

/// glab for one merge request, !42 on `feature`, answering the API reads and the mr commands.
private actor MergeGlab {
    private var head: String
    private let rebasedHead: String?
    private let extraAfterRebase: String?
    private var merged = false
    private(set) var merges: [[String]] = []
    private(set) var creates: [[String]] = []
    private(set) var rebases = 0

    init(head: String, rebasedHead: String? = nil, extraAfterRebase: String? = nil) {
        self.head = head
        self.rebasedHead = rebasedHead
        self.extraAfterRebase = extraAfterRebase
    }

    func execute(_ arguments: [String]) -> ShellResult {
        if arguments.starts(with: ["mr", "merge"]) {
            merges.append(arguments)
            merged = true
            return ShellResult(status: 0, stdout: "", stderr: "")
        }
        if arguments.starts(with: ["mr", "create"]) {
            creates.append(arguments)
            return ShellResult(status: 0, stdout: "https://gitlab.com/group/app/-/merge_requests/42\n", stderr: "")
        }
        if arguments.starts(with: ["mr", "rebase"]) {
            rebases += 1
            head = rebasedHead ?? head
            return ShellResult(status: 0, stdout: "", stderr: "")
        }
        if arguments.last?.hasSuffix("/commits?per_page=100") == true {
            let extra = rebases > 0 ? extraAfterRebase.map { [(String(repeating: "c", count: 40), $0)] } ?? [] : []
            let commits = extra + [(head, "Add a")]
            let listed = commits.map { #"{"id":"\#($0.0)","title":"\#($0.1)"}"# }.joined(separator: ",")
            return ShellResult(status: 0, stdout: "[\(listed)]", stderr: "")
        }
        let state = merged ? "merged" : "opened"
        return ShellResult(status: 0, stdout: """
            {"iid":42,"title":"Feature","web_url":"https://gitlab.com/group/app/-/merge_requests/42",\
            "state":"\(state)","draft":false,"has_conflicts":false,"detailed_merge_status":"mergeable",\
            "source_branch":"feature","target_branch":"main","sha":"\(head)",\
            "source_project_id":1,"target_project_id":1}
            """, stderr: "")
    }
}
