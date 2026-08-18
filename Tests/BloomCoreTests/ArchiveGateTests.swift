import Testing
import Foundation
@testable import BloomCore

/// What decides whether archiving a workspace asks first.
///
/// This is the one piece of logic in the app that decides whether work gets destroyed, so it is
/// tested as a value rather than only through git. The pure cases below name every combination
/// that changes the answer; the git-driven ones after them prove the same rules hold against a
/// real repository, including the squash merge that git and GitHub disagree about.
@Suite("Archive gate", .tags(.git), .scratchDirectory)
struct ArchiveGateTests {
    // MARK: - The predicate

    @Test("a clean worktree with no commits of its own is safe either way")
    func cleanAndEmptyIsSafe() {
        let report = WorkspaceSafetyReport()
        #expect(report.isSafeToDiscard(deletingBranch: true))
        #expect(report.isSafeToDiscard(deletingBranch: false))
        #expect(report.losses(deletingBranch: true).isEmpty)
    }

    @Test("commits of its own only matter when the branch goes too")
    func commitsMatterOnlyWhenDeletingTheBranch() {
        let report = WorkspaceSafetyReport(unpushedCommits: 3)

        // Removing a worktree is removing a checkout. The branch is what holds the commits, so
        // an archive that keeps it strands nothing and needs no confirmation.
        #expect(report.isSafeToDiscard(deletingBranch: false))
        #expect(report.losses(deletingBranch: false).isEmpty)

        #expect(report.isSafeToDiscard(deletingBranch: true) == false)
        #expect(report.losses(deletingBranch: true).count == 1)
    }

    @Test("a merged pull request answers for the commits when git cannot")
    func mergedPullRequestClearsTheCommits() {
        // The squash merge case: GitHub rewrote these commits onto the base branch, so git's
        // reachability test says the branch is not merged while every line of its work is safe.
        let report = WorkspaceSafetyReport(unpushedCommits: 3, isBranchMerged: false)

        #expect(report.isSafeToDiscard(deletingBranch: true) == false)
        #expect(report.isSafeToDiscard(deletingBranch: true, isPullRequestMerged: true))
        #expect(report.losses(deletingBranch: true, isPullRequestMerged: true).isEmpty)
    }

    @Test("a merged pull request never excuses work that was never committed")
    func mergedPullRequestDoesNotExcuseTheWorkingCopy() {
        // The pull request says something about the commits. It says nothing at all about the
        // files sitting in the directory that is about to be deleted.
        for report in [
            WorkspaceSafetyReport(hasUncommittedChanges: true),
            WorkspaceSafetyReport(untrackedFiles: ["plan.md"]),
            WorkspaceSafetyReport(modifiedIgnoredFiles: [".env"]),
            WorkspaceSafetyReport(detachedCommits: 2),
        ] {
            #expect(report.isSafeToDiscard(deletingBranch: true, isPullRequestMerged: true) == false)
            #expect(report.isSafeToDiscard(deletingBranch: false, isPullRequestMerged: true) == false)
        }
    }

    @Test("commits made on a detached HEAD are not in anybody's pull request")
    func detachedCommitsAreNeverExcused() {
        let report = WorkspaceSafetyReport(detachedCommits: 1)
        #expect(report.isSafeToDiscard(deletingBranch: false) == false)
        #expect(report.losses(deletingBranch: false).contains { $0.contains("detached HEAD") })
    }

    @Test("the plain property is still the cautious answer")
    func thePlainPropertyAssumesTheBranchGoes() {
        let report = WorkspaceSafetyReport(unpushedCommits: 1)
        #expect(report.isSafeToDiscard == false)
        #expect(report.isSafeToDiscard == report.isSafeToDiscard(deletingBranch: true))
        #expect(report.losses == report.losses(deletingBranch: true))
    }

    // MARK: - Against a real repository

    private func makeWorkspace() async throws
        -> (repo: TempRepo, registered: Repo, manager: WorkspaceManager, workspace: Workspace) {
        let repo = try await TempRepo()
        let manager = WorkspaceManager(store: try makeTestStore("archive-gate"))
        let registered = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(repo: registered, prompt: "Do the thing")
        return (repo, registered, manager, workspace)
    }

    private func commit(in worktree: String, message: String) async throws {
        try await Shell.check("git", ["add", "-A"], cwd: worktree)
        try await Shell.check("git", [
            "-c", "user.email=test@bloom.local", "-c", "user.name=Bloom Test",
            "-c", "commit.gpgsign=false",
            "commit", "-q", "-m", message,
        ], cwd: worktree)
    }

    @Test("keeping the branch archives a workspace whose commits exist nowhere else", .tags(.destructive))
    func keepingTheBranchNeedsNoConfirmation() async throws {
        let (repo, registered, manager, workspace) = try await makeWorkspace()
        defer { repo.cleanUp() }

        try TempRepo(existing: workspace.path).write("feature.txt", "work that exists nowhere else\n")
        try await commit(in: workspace.path, message: "unpublished work")

        let report = try await manager.safetyReport(workspace: workspace, repo: registered)
        #expect(report.unpushedCommits == 1)
        #expect(report.isBranchMerged == false)

        // Deleting the branch would strand the commit, so that form still refuses.
        await #expect(throws: WorkspaceError.self) {
            try await manager.archive(workspace: workspace, repo: registered, deleteBranch: true)
        }

        // Keeping it strands nothing, so this one goes straight through.
        try await manager.archive(workspace: workspace, repo: registered, deleteBranch: false)
        #expect(FileManager.default.fileExists(atPath: workspace.path) == false)
        #expect(await Git.branchExists(workspace.branch, in: repo.path))
    }

    @Test("a squash merged branch is refused by git alone and cleared by GitHub", .tags(.destructive))
    func squashMergeIsClearedByThePullRequest() async throws {
        let (repo, registered, manager, workspace) = try await makeWorkspace()
        defer { repo.cleanUp() }

        let worktree = TempRepo(existing: workspace.path)
        try worktree.write("feature.txt", "the whole feature\n")
        try await commit(in: workspace.path, message: "the feature")

        // A squash merge, as GitHub performs one: the same content lands on main as a new commit
        // whose history has nothing to do with the branch's. `git merge-base --is-ancestor` is
        // false afterwards, which is why git alone gets this case wrong.
        try await Shell.check("git", ["merge", "--squash", workspace.branch], cwd: repo.path)
        try await Shell.check(
            "git",
            [
                "-c", "user.email=test@bloom.local", "-c", "user.name=Bloom Test",
                "-c", "commit.gpgsign=false",
                "commit", "-q", "-m", "the feature (#7)",
            ],
            cwd: repo.path
        )

        let report = try await manager.safetyReport(workspace: workspace, repo: registered)
        #expect(report.isBranchMerged == false, "git cannot see a squash merge")
        #expect(report.unpushedCommits == 1)
        #expect(report.isSafeToDiscard(deletingBranch: true) == false)

        await #expect(throws: WorkspaceError.self) {
            try await manager.archive(workspace: workspace, repo: registered, deleteBranch: true)
        }

        try await manager.archive(
            workspace: workspace, repo: registered, deleteBranch: true, isPullRequestMerged: true
        )
        #expect(FileManager.default.fileExists(atPath: workspace.path) == false)
        #expect(await Git.branchExists(workspace.branch, in: repo.path) == false)
    }

    @Test("a merged pull request does not archive over uncommitted work", .tags(.destructive))
    func mergedPullRequestStillRefusesADirtyWorktree() async throws {
        let (repo, registered, manager, workspace) = try await makeWorkspace()
        defer { repo.cleanUp() }

        let worktree = TempRepo(existing: workspace.path)
        try worktree.write("README.md", "hello\nedited after the merge\n")

        await #expect(throws: WorkspaceError.self) {
            try await manager.archive(
                workspace: workspace, repo: registered, deleteBranch: true, isPullRequestMerged: true
            )
        }
        #expect(worktree.read("README.md") == "hello\nedited after the merge\n")
    }
}
