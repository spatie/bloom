import Foundation
import Testing
@testable import BloomCore

/// Which branch a pull request lookup names.
///
/// The report: an agent opened https://github.com/spatie/laravel-mailcoach/pull/2073, said so in
/// the transcript, and the strip went on offering Create pull request minutes after the turn had
/// finished. Its head was `fix/issue-2069-transactional-mail-admin-preview`, a branch the agent
/// cut from `origin/main` itself, and Bloom was asking gh about the branch written down when the
/// workspace was created. Every poll asked again and got the same nothing, so nothing here is
/// about a cache: the question was wrong.
@Suite("Which branch a pull request is looked up by")
struct PullRequestHeadTests {
    @Test("The branch the worktree is on now wins over the one recorded at creation")
    func prefersTheCheckedOutBranch() {
        #expect(
            PullRequestHead.branch(
                recorded: "bloom/preview-crash",
                checkedOut: "fix/issue-2069-transactional-mail-admin-preview",
                base: "main"
            ) == "fix/issue-2069-transactional-mail-admin-preview"
        )
    }

    @Test("A detached HEAD leaves the recorded branch as the only name there is")
    func fallsBackWhenDetached() {
        // A rebase, a bisect, or a commit checked out to look at.
        #expect(
            PullRequestHead.branch(recorded: "bloom/preview-crash", checkedOut: nil, base: "main")
                == "bloom/preview-crash"
        )
        #expect(
            PullRequestHead.branch(recorded: "bloom/preview-crash", checkedOut: "  ", base: "main")
                == "bloom/preview-crash"
        )
    }

    @Test("A worktree standing on the base branch is not asked about")
    func refusesTheBaseBranch() {
        // `gh pr view main` answers about somebody's fork, not about this workspace.
        #expect(
            PullRequestHead.branch(recorded: "bloom/preview-crash", checkedOut: "main", base: "main")
                == "bloom/preview-crash"
        )
    }

    @Test("A row with no branch name in it is not a name to prefer")
    func toleratesAnEmptyRecord() {
        #expect(PullRequestHead.branch(recorded: "", checkedOut: "main", base: "main") == "main")
        #expect(PullRequestHead.branch(recorded: "", checkedOut: nil, base: "main") == "")
    }
}

@Suite("The branch gh is asked about", .tags(.git), .scratchDirectory)
struct PullRequestHeadBranchTests {
    @Test("A worktree the agent moved to a new branch is looked up under that branch")
    func readsTheBranchOffDisk() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }

        let workspace = Workspace(
            repoID: RepoID.new(),
            name: "Preview crash",
            branch: "bloom/preview-crash",
            path: repo.path,
            baseBranch: "main"
        )

        // Standing on the base branch, so the recorded name is what gets asked about.
        #expect(await GitHub.headBranch(of: workspace) == "bloom/preview-crash")

        // Exactly what the agent did: a branch of its own, cut from the base.
        try await Shell.check(
            "git", ["checkout", "-q", "-b", "fix/issue-2069-preview"], cwd: repo.path
        )
        #expect(await GitHub.headBranch(of: workspace) == "fix/issue-2069-preview")
    }
}
