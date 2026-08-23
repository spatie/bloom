import Foundation
import Testing
@testable import BloomCore

/// What an agent is told when `workspace_start` could not cut a worktree.
///
/// Every failure here is provoked by running the real `Git.addWorktree` against a real repository,
/// because the point of the change these tests pin is that git's own words were not enough: two of
/// the three cases produce the identical stderr, and the third never reaches git at all. Inventing
/// the errors would have hidden exactly that.
@Suite("workspace_start failures", .tags(.git, .subprocess), .scratchDirectory)
struct WorkspaceStartFailureTests {
    /// A repository that has been initialised and never committed to.
    private func emptyRepository() async throws -> String {
        let path = TestScratch.unique("bloom-git")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try await Shell.check("git", ["init", "-q", "-b", "main"], cwd: path)
        return path
    }

    private func failureAddingWorktree(
        repo: String,
        branch: String = "do-thing",
        base: String
    ) async -> (any Error)? {
        do {
            try await Git.addWorktree(
                repo: repo,
                path: TestScratch.unique("worktree") + "/\(branch)",
                branch: branch,
                base: base
            )
            return nil
        } catch {
            return error
        }
    }

    /// The trap. git says "invalid reference: main" for a repository with no commits, which reads
    /// as a typo, so a model retries with master and develop and trunk and gets the same eight
    /// words each time.
    @Test("a repository with no commits says so, rather than blaming the branch name")
    func noCommits() async throws {
        let repo = try await emptyRepository()
        let error = try #require(await failureAddingWorktree(repo: repo, base: "main"))

        // The shape this is defending against, measured rather than assumed.
        #expect(error.readableMessage.contains("invalid reference: main"))

        let trouble = await WorkspaceStartTrouble.diagnose(
            error, project: "flare", projectPath: repo, baseBranch: "main", wasRequested: false
        )

        #expect(trouble == .noCommitsYet(project: "flare"))
        #expect(trouble.sentence.contains("has no commits yet"))
        #expect(trouble.sentence.contains("do not retry with another one"))
        #expect(!trouble.sentence.contains("invalid reference"))
    }

    /// The recoverable one, and it stays recoverable: the branch is named and so is what would
    /// have worked instead.
    @Test("a base branch that does not exist names it and names the branches that do")
    func missingBaseBranch() async throws {
        let repo = try await TempRepo()
        try await Shell.check("git", ["branch", "develop"], cwd: repo.path)
        let error = try #require(await failureAddingWorktree(repo: repo.path, base: "no-such-branch"))

        let trouble = await WorkspaceStartTrouble.diagnose(
            error,
            project: "flare",
            projectPath: repo.path,
            baseBranch: "no-such-branch",
            wasRequested: true
        )

        #expect(trouble == .baseBranchMissing(
            branch: "no-such-branch",
            project: "flare",
            wasRequested: true,
            branches: ["develop", "main"]
        ))
        #expect(trouble.sentence.contains("no branch called 'no-such-branch'"))
        #expect(trouble.sentence.contains("'develop' and 'main'"))
        #expect(trouble.sentence.contains("as base_branch"))
    }

    /// A caller that left `base_branch` out never chose the branch it is being told about, so
    /// telling it the name is missing without saying whose name it is invites it to guess.
    @Test("a missing default branch says it is the default, since the caller never named it")
    func missingDefaultBranch() async throws {
        let repo = try await TempRepo(defaultBranch: "trunk")
        let error = try #require(await failureAddingWorktree(repo: repo.path, base: "main"))

        let trouble = await WorkspaceStartTrouble.diagnose(
            error, project: "flare", projectPath: repo.path, baseBranch: "main", wasRequested: false
        )

        #expect(trouble.sentence.contains("the default branch Bloom cuts from"))
        #expect(trouble.sentence.contains("'trunk'"))
    }

    /// Deleting the project does not produce a git error at all: the subprocess cannot be launched
    /// in a directory that is gone, and Foundation's complaint names only the last path component.
    @Test("a project that is gone from disk says the project is gone, not that a file is missing")
    func projectDeleted() async throws {
        let repo = try await TempRepo()
        try FileManager.default.removeItem(atPath: repo.path)
        let error = try #require(await failureAddingWorktree(repo: repo.path, base: "main"))

        #expect(!error.readableMessage.contains(repo.path))

        let trouble = await WorkspaceStartTrouble.diagnose(
            error, project: "flare", projectPath: repo.path, baseBranch: "main", wasRequested: false
        )

        #expect(trouble == .projectMissingFromDisk(project: "flare", path: repo.path))
        #expect(trouble.sentence.contains("no longer on disk"))
        #expect(trouble.sentence.contains("Retrying will not help"))
    }

    /// Anything unrecognised still reaches the caller, but without the argv Bloom built. The
    /// command line is the one part of the failure the caller neither chose nor can change.
    @Test("an unrecognised git failure keeps git's words and drops the command line")
    func unexplainedDropsTheCommandLine() async throws {
        let repo = try await TempRepo()
        let error = ShellError(
            command: "git worktree add -b do-thing -- /Users/freek/bloom/workspaces/bloom-git-711961F7/do-thing main",
            status: 128,
            stderr: "fatal: disk quota exceeded"
        )

        let trouble = await WorkspaceStartTrouble.diagnose(
            error, project: "flare", projectPath: repo.path, baseBranch: "main", wasRequested: false
        )

        #expect(trouble == .unexplained("fatal: disk quota exceeded."))
        #expect(!trouble.sentence.contains("worktree add"))
        #expect(!trouble.sentence.contains("bloom-git-711961F7"))
    }

    /// The leak that started this. None of the sentences may carry the argv or a path inside
    /// Bloom's own worktree root, whatever the cause.
    @Test("no sentence quotes a git command line or an internal worktree path")
    func nothingLeaks() async throws {
        let repo = try await emptyRepository()
        let error = try #require(await failureAddingWorktree(repo: repo, base: "main"))

        let troubles = [
            await WorkspaceStartTrouble.diagnose(
                error, project: "flare", projectPath: repo, baseBranch: "main", wasRequested: false
            ),
            .projectMissingFromDisk(project: "flare", path: "/tmp/flare"),
            .baseBranchMissing(branch: "x", project: "flare", wasRequested: true, branches: ["main"]),
            .noCommitsYet(project: "flare"),
        ] as [WorkspaceStartTrouble]

        for trouble in troubles {
            #expect(!trouble.sentence.contains("git worktree"))
            #expect(!trouble.sentence.contains("exited 128"))
            #expect(!trouble.sentence.contains("workspaces/bloom-git"))
        }
    }

    /// A repository with two hundred branches would otherwise spend the whole tool result listing
    /// them.
    @Test("the branch listing is capped")
    func branchListingIsCapped() {
        let branches = (1...25).map { "feature/\($0)" }
        let sentence = WorkspaceStartTrouble.baseBranchMissing(
            branch: "nope", project: "flare", wasRequested: true, branches: branches
        ).sentence

        #expect(sentence.contains("and 15 more"))
        #expect(!sentence.contains("feature/20"))
    }
}
