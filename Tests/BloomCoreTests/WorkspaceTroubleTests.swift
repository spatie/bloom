import Testing
import Foundation
@testable import BloomCore

/// A directory that Bloom recorded and that has stopped being a checkout, asked to do each of the
/// things Bloom does in it.
///
/// The bug behind this suite: creating a workspace put up a modal reading "`git for-each-ref
/// --format=%(refname:short) refs/heads` exited 128: fatal: not a git repository (or any of the
/// parent directories): .git", and the inspector said the same about `git rev-parse --verify
/// main^{commit}` for a different workspace in the same window. Both were the raw `ShellError`.
@Suite("Trouble with a recorded directory", .tags(.git, .destructive), .scratchDirectory)
struct WorkspaceTroubleTests {
    // MARK: - The probes

    @Test("asks the path rather than reading git's stderr")
    func standingOfEveryState() async throws {
        let repo = try await TempRepo(defaultBranch: "main")
        defer { repo.cleanUp() }

        #expect(await CheckoutStanding.of(repo.path, branch: "main") == .fine)
        #expect(await CheckoutStanding.of(repo.path, branch: "nope") == .branchMissing("nope"))
        #expect(await CheckoutStanding.of(repo.path + "-gone") == .missing)

        let plain = TestScratch.unique("plain")
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        #expect(await CheckoutStanding.of(plain) == .notACheckout)

        let fresh = TestScratch.unique("fresh")
        try FileManager.default.createDirectory(atPath: fresh, withIntermediateDirectories: true)
        try await Shell.check("git", ["init", "-q", "-b", "main"], cwd: fresh)
        #expect(await CheckoutStanding.of(fresh) == .noCommitsYet)
    }

    /// The command line is the one part of a failure the reader neither chose nor can change.
    @Test("drops the command line from git's complaint")
    func complaintDropsTheCommand() {
        let error = ShellError(
            command: "git for-each-ref --format=%(refname:short) refs/heads",
            status: 128,
            stderr: "fatal: not a git repository (or any of the parent directories): .git"
        )
        let complaint = CheckoutStanding.complaint(about: error)
        #expect(complaint == "fatal: not a git repository (or any of the parent directories): .git.")
        #expect(!complaint.contains("for-each-ref"))
    }

    // MARK: - Creating a workspace

    @Test("names the project and its folder when the project has gone")
    func creatingInAProjectThatHasGone() async throws {
        let path = TestScratch.unique("harbour")
        let trouble = await WorkspaceTrouble.creating(
            ShellError(command: "git for-each-ref", status: 128, stderr: "fatal: not a git repository"),
            project: "harbour", projectPath: path, baseBranch: "main"
        )
        #expect(trouble == .projectGone(project: "harbour", path: path))
        #expect(trouble.sentence.contains("The project 'harbour' is no longer at \(path)."))
        #expect(trouble.sentence.contains("add it again"))
        #expect(!trouble.sentence.contains("for-each-ref"))
        #expect(!trouble.sentence.contains("`"))
    }

    /// The state Freek's machine was in: a folder still there, with no `.git` in it or above it.
    @Test("says a project folder is no longer a checkout, rather than quoting git")
    func creatingInAFolderThatIsNoLongerACheckout() async throws {
        let repo = try await TempRepo(defaultBranch: "main")
        defer { repo.cleanUp() }
        try FileManager.default.removeItem(atPath: repo.path + "/.git")

        // The failure the sheet would actually be holding, produced by running the real command.
        let error = await #expect(throws: (any Error).self) {
            try await Git.branches(of: repo.path)
        }
        let trouble = await WorkspaceTrouble.creating(
            error ?? ShellError(command: "git", status: 128, stderr: ""),
            project: "bloom", projectPath: repo.path, baseBranch: "main"
        )
        #expect(trouble == .projectNotACheckout(project: "bloom", path: repo.path))
        #expect(trouble.sentence.contains("is not a git repository any more"))
        #expect(!trouble.sentence.contains("for-each-ref"))
        #expect(!trouble.sentence.contains("exited 128"))
    }

    @Test("says which branch is gone when the base branch has been deleted")
    func creatingFromABranchThatIsGone() async throws {
        let repo = try await TempRepo(defaultBranch: "main")
        defer { repo.cleanUp() }

        let trouble = await WorkspaceTrouble.creating(
            ShellError(command: "git worktree add", status: 128, stderr: "fatal: invalid reference"),
            project: "bloom", projectPath: repo.path, baseBranch: "release"
        )
        #expect(trouble == .baseBranchGone(branch: "release", project: "bloom"))
        #expect(trouble.sentence.contains("no branch called 'release'"))
    }

    @Test("passes a failure through when the project is perfectly healthy")
    func creatingInAHealthyProject() async throws {
        let repo = try await TempRepo(defaultBranch: "main")
        defer { repo.cleanUp() }

        let trouble = await WorkspaceTrouble.creating(
            WorkspaceError.pathInUse("/somewhere"),
            project: "bloom", projectPath: repo.path, baseBranch: "main"
        )
        #expect(trouble == .unexplained("/somewhere already exists."))
    }

    // MARK: - Reading the changes

    @Test("names the workspace, not its path, when the worktree has been deleted")
    func readingChangesWithNoWorktree() async throws {
        let repo = try await TempRepo(defaultBranch: "main")
        defer { repo.cleanUp() }
        let worktree = TestScratch.unique("wt")
        try await Git.addWorktree(repo: repo.path, path: worktree, branch: "sidebar-blue", base: "main")
        try FileManager.default.removeItem(atPath: worktree)

        // Launching a subprocess in a deleted directory throws before git runs at all, which is
        // why the stderr can never be what decides this.
        let error = await #expect(throws: (any Error).self) {
            try await Git.changedFiles(worktree: worktree, base: "main")
        }
        let trouble = await WorkspaceTrouble.readingChanges(
            error ?? ShellError(command: "git", status: 128, stderr: ""),
            workspace: "Sidebar blue", path: worktree, baseBranch: "main"
        )
        #expect(trouble == .worktreeGone(workspace: "Sidebar blue"))
        #expect(trouble.sentence.contains("The worktree for 'Sidebar blue' is not on disk any more."))
        #expect(trouble.sentence.contains("archive this workspace"))
        #expect(!trouble.sentence.contains(worktree))
    }

    /// A folder deleted and then recreated, which is what was actually left behind on the machine
    /// this was found on: one `.DS_Store` and nothing else.
    @Test("says a worktree folder is no longer a worktree")
    func readingChangesWithARecreatedFolder() async throws {
        let repo = try await TempRepo(defaultBranch: "main")
        defer { repo.cleanUp() }
        let worktree = TestScratch.unique("wt")
        try await Git.addWorktree(repo: repo.path, path: worktree, branch: "limits-panel", base: "main")
        try FileManager.default.removeItem(atPath: worktree)
        try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)

        let error = await #expect(throws: (any Error).self) {
            try await Git.changedFiles(worktree: worktree, base: "main")
        }
        // The exact modal Freek was shown, which is what has to stop reaching a reader.
        #expect("\(error!)".contains("rev-parse"))

        let trouble = await WorkspaceTrouble.readingChanges(
            error!, workspace: "Limits panel", path: worktree, baseBranch: "main"
        )
        #expect(trouble == .worktreeNotACheckout(workspace: "Limits panel"))
        #expect(trouble.sentence.contains("git does not know it as a worktree any more"))
        #expect(!trouble.sentence.contains("rev-parse"))
        #expect(!trouble.sentence.contains("`"))
    }

    @Test("says which base branch went missing under a healthy worktree")
    func readingChangesWithNoBaseBranch() async throws {
        let repo = try await TempRepo(defaultBranch: "main")
        defer { repo.cleanUp() }
        let worktree = TestScratch.unique("wt")
        try await Git.addWorktree(repo: repo.path, path: worktree, branch: "retry-surfaces", base: "main")
        defer { try? FileManager.default.removeItem(atPath: worktree) }

        let trouble = await WorkspaceTrouble.readingChanges(
            ShellError(command: "git merge-base", status: 128, stderr: "fatal: bad revision"),
            workspace: "Retry surfaces", path: worktree, baseBranch: "release"
        )
        #expect(trouble == .worktreeBaseBranchGone(branch: "release", workspace: "Retry surfaces"))
        #expect(trouble.sentence.contains("'release', the branch 'Retry surfaces' is measured against"))
    }

    // MARK: - One missing worktree does not take down the rest

    /// The question the modal raised: creating workspace B should not care that workspace A's
    /// folder has gone. It reads its branches from the project, which is still there.
    @Test("creates a workspace while another workspace's worktree is missing")
    func createsWhileAnotherWorktreeIsMissing() async throws {
        let repo = try await TempRepo(defaultBranch: "main")
        defer { repo.cleanUp() }
        let manager = WorkspaceManager(store: try makeTestStore("trouble"))
        let registered = try await manager.addRepository(at: repo.path)

        let first = try await manager.createWorkspace(repo: registered, prompt: "Sidebar blue")
        try FileManager.default.removeItem(atPath: first.path)

        let second = try await manager.createWorkspace(repo: registered, prompt: "Limits panel")
        #expect(second.branch == "limits-panel")
        #expect(FileManager.default.fileExists(atPath: second.path + "/README.md"))

        // And the workspace whose folder went is diagnosed rather than reported.
        let error = await #expect(throws: (any Error).self) {
            try await Git.changedFiles(worktree: first.path, base: first.baseBranch)
        }
        let trouble = await WorkspaceTrouble.readingChanges(
            error!, workspace: first.name, path: first.path, baseBranch: first.baseBranch
        )
        #expect(trouble == .worktreeGone(workspace: first.name))
    }
}
