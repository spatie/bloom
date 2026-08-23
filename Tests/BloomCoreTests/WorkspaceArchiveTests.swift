import Testing
import Foundation
@testable import BloomCore

/// `WorkspaceManager.archive` is the only thing in Bloom that deletes a git worktree and can
/// delete a branch, and none of it is undoable. It refuses unless `WorkspaceSafetyReport` says
/// the work is expendable, so every one of these tests asks the same question a different way:
/// can this path throw work away without saying so first?
@Suite("Workspace archiving", .tags(.git, .destructive), .scratchDirectory)
struct WorkspaceArchiveTests {
    private func makeWorkspace(
        settings: String? = nil,
        prompt: String = "Archive safety"
    ) async throws -> (repo: TempRepo, registered: Repo, manager: WorkspaceManager, workspace: Workspace) {
        let repo = try await TempRepo()
        if let settings { try repo.write(".conductor/settings.toml", settings) }
        let manager = WorkspaceManager(store: try makeTestStore("archive"))
        let registered = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(repo: registered, prompt: prompt)
        return (repo, registered, manager, workspace)
    }

    private func commit(in worktree: String, message: String) async throws {
        try await Shell.check("git", ["add", "-A"], cwd: worktree)
        try await Shell.check("git", [
            "-c", "user.email=test@bloom.local", "-c", "user.name=Bloom Test",
            "-c", "commit.gpgsign=false", "commit", "-q", "-m", message,
        ], cwd: worktree)
    }

    // MARK: - The setting cannot bypass the gate

    @Test("delete_branch_on_archive drives branch deletion when the caller says nothing")
    func settingDrivesBranchDeletion() async throws {
        let (repo, registered, manager, workspace) = try await makeWorkspace(settings: """
        [git]
        delete_branch_on_archive = true
        """)
        defer { repo.cleanUp() }

        try await manager.archive(workspace: workspace, repo: registered)
        #expect(await Git.branchExists(workspace.branch, in: repo.path) == false)
    }

    @Test("an explicit false beats a settings file that says delete")
    func explicitArgumentBeatsTheSetting() async throws {
        let (repo, registered, manager, workspace) = try await makeWorkspace(settings: """
        [git]
        delete_branch_on_archive = true
        """)
        defer { repo.cleanUp() }

        try await manager.archive(workspace: workspace, repo: registered, deleteBranch: false)
        #expect(await Git.branchExists(workspace.branch, in: repo.path))
    }

    @Test("a settings file asking for deletion cannot skip the safety report")
    func settingCannotBypassTheReport() async throws {
        let (repo, registered, manager, workspace) = try await makeWorkspace(settings: """
        [git]
        delete_branch_on_archive = true
        """)
        defer { repo.cleanUp() }

        // Work that exists nowhere else, on a repo configured to delete branches on archive. The
        // setting decides *whether the branch goes*, never *whether the check runs*.
        try TempRepo(existing: workspace.path).write("feature.txt", "only copy\n")
        try await commit(in: workspace.path, message: "only copy")
        let sha = try await Git.headSHA(of: workspace.path)

        await #expect(throws: WorkspaceError.self) {
            try await manager.archive(workspace: workspace, repo: registered)
        }
        #expect(await Git.branchExists(workspace.branch, in: repo.path))
        #expect(FileManager.default.fileExists(atPath: workspace.path + "/feature.txt"))
        let reachable = try await Shell.run("git", ["cat-file", "-e", "\(sha)^{commit}"], cwd: repo.path)
        #expect(reachable.ok)
    }

    // MARK: - Ordering: nothing is removed before the wind-down succeeded

    @Test("force does not skip the archive script, so a failed wind-down still stops everything")
    func forceDoesNotSkipTheArchiveScript() async throws {
        let (repo, registered, manager, workspace) = try await makeWorkspace(settings: """
        [scripts]
        archive = 'exit 9'
        """)
        defer { repo.cleanUp() }

        // `force` means "I accept losing the work", not "skip winding the workspace down". A
        // container still running or a database still mounted is not something force asked for.
        let error = await #expect(throws: WorkspaceError.self) {
            try await manager.archive(workspace: workspace, repo: registered, force: true)
        }
        guard case .archiveScriptFailed(let status, _)? = error else {
            Issue.record("expected archiveScriptFailed, got \(String(describing: error))")
            return
        }
        #expect(status == 9)
        #expect(FileManager.default.fileExists(atPath: workspace.path))
        #expect(await Git.branchExists(workspace.branch, in: repo.path))
        #expect(try await manager.store.workspace(id: workspace.id)?.state != .archived)
    }

    /// The archive script used to be handed `BLOOM_PORT=0`, whatever block the workspace was
    /// actually holding. A teardown script's job is to undo what the setup script did, and half
    /// of what a setup script does is bound to that port: the container publishing it, the
    /// process listening on it, the site pointed at it. With zero there was nothing to look for,
    /// and a `docker compose down` reading the port out of its own file brought down a stack that
    /// did not exist.
    @Test("the archive script is handed the same port the setup script was")
    func theArchiveScriptSeesTheWorkspacePort() async throws {
        let (repo, registered, manager, workspace) = try await makeWorkspace(settings: """
        [scripts]
        archive = 'printf %s "$BLOOM_PORT" > "$BLOOM_ROOT_PATH/archived-on-port"; printf %s "$CONDUCTOR_PORT" > "$BLOOM_ROOT_PATH/archived-on-alias"'
        """)
        defer { repo.cleanUp() }

        // What the setup script would have been given, and written into a .env by now.
        let port = await manager.ensurePort(for: workspace)
        #expect(port != 0)

        try await manager.archive(workspace: workspace, repo: registered, deleteBranch: false)

        // Written outside the worktree on purpose: the worktree is gone by the time this reads it.
        let written = try String(contentsOfFile: repo.path + "/archived-on-port", encoding: .utf8)
        #expect(written == String(port))
        let alias = try String(contentsOfFile: repo.path + "/archived-on-alias", encoding: .utf8)
        #expect(alias == String(port))
    }

    /// The value the caller is holding can predate the allocation: the sidebar reads a row, the
    /// workspace is opened, a terminal asks for a block, and then the archive runs against the
    /// row as it was read.
    @Test("the archive reads the port from the row rather than from the value handed to it")
    func theArchivePortComesFromTheRow() async throws {
        let (repo, registered, manager, workspace) = try await makeWorkspace(settings: """
        [scripts]
        archive = 'printf %s "$BLOOM_PORT" > "$BLOOM_ROOT_PATH/archived-on-port"'
        """)
        defer { repo.cleanUp() }

        // `workspace` here is the value from before the block was allocated, and still says 0.
        let port = await manager.ensurePort(for: workspace)
        #expect(workspace.port == 0)

        try await manager.archive(workspace: workspace, repo: registered, deleteBranch: false)

        let written = try String(contentsOfFile: repo.path + "/archived-on-port", encoding: .utf8)
        #expect(written == String(port))
    }

    /// The budget a real teardown gets. Two minutes covered `DROP DATABASE` and nothing else:
    /// `docker compose down -v` over a handful of services, each with its own stop grace period
    /// before the kill and then the volumes to remove, runs past it on a loaded machine, and the
    /// archive it was tearing down failed with the containers still up.
    @Test("an archive script is given long enough for a real teardown")
    func theArchiveScriptBudgetFitsARealTeardown() {
        #expect(WorkspaceManager.archiveScriptTimeout >= .seconds(300))
    }

    /// And it is still a budget. A script that never returns holds the workspace open forever,
    /// with nothing to reap the process, which is worse than one that gives up. When it does give
    /// up the archive is abandoned exactly as any other failure abandons it: the worktree stays,
    /// the branch stays, and the row does not claim the workspace is gone.
    @Test("an archive script that runs past its budget is killed and the archive abandoned")
    func anOverrunningArchiveScriptStopsTheArchive() async throws {
        let (repo, registered, manager, workspace) = try await makeWorkspace(settings: """
        [scripts]
        archive = 'sleep 120'
        """)
        defer { repo.cleanUp() }

        await #expect(throws: WorkspaceError.self) {
            try await manager.archive(
                workspace: workspace, repo: registered, archiveScriptTimeout: .seconds(1)
            )
        }

        #expect(FileManager.default.fileExists(atPath: workspace.path))
        #expect(await Git.branchExists(workspace.branch, in: repo.path))
        #expect(try await manager.store.workspace(id: workspace.id)?.state != .archived)
    }

    @Test("a refusal is not sticky: cleaning the worktree makes the same workspace archivable")
    func refusalIsNotSticky() async throws {
        let (repo, registered, manager, workspace) = try await makeWorkspace()
        defer { repo.cleanUp() }

        let worktree = TempRepo(existing: workspace.path)
        try worktree.write("scratch.txt", "throwaway\n")
        await #expect(throws: WorkspaceError.self) {
            try await manager.archive(workspace: workspace, repo: registered)
        }

        try FileManager.default.removeItem(atPath: workspace.path + "/scratch.txt")
        #expect(worktree.exists("scratch.txt") == false)

        try await manager.archive(workspace: workspace, repo: registered)
        #expect(FileManager.default.fileExists(atPath: workspace.path) == false)
        #expect(try await manager.store.workspace(id: workspace.id)?.state == .archived)
    }

    @Test("a worktree somebody already deleted by hand still archives cleanly")
    func archivesAWorktreeThatIsAlreadyGone() async throws {
        let (repo, registered, manager, workspace) = try await makeWorkspace()
        defer { repo.cleanUp() }

        // `git worktree remove` refuses a directory that is not there, so without the prune
        // fallback this workspace could never be got rid of through the UI.
        try FileManager.default.removeItem(atPath: workspace.path)

        try await manager.archive(workspace: workspace, repo: registered)
        #expect(try await manager.store.workspace(id: workspace.id)?.state == .archived)
        #expect(try await Git.worktrees(of: repo.path).count == 1)
        // Nothing was committed, so the branch is expendable, but it is still kept by default.
        #expect(await Git.branchExists(workspace.branch, in: repo.path))
    }

    @Test("forcing over a dirty worktree destroys exactly what the report listed")
    func forceDestroysOnlyWhatWasReported() async throws {
        let (repo, registered, manager, workspace) = try await makeWorkspace()
        defer { repo.cleanUp() }

        let worktree = TempRepo(existing: workspace.path)
        try worktree.write("README.md", "edited\n")
        try worktree.write("notes.txt", "untracked\n")

        let report = try await manager.safetyReport(workspace: workspace, repo: registered)
        #expect(report.losses.count == 2)

        try await manager.archive(workspace: workspace, repo: registered, deleteBranch: true, force: true)
        #expect(FileManager.default.fileExists(atPath: workspace.path) == false)
        #expect(await Git.branchExists(workspace.branch, in: repo.path) == false)
        // The main checkout is a different directory and must be untouched by any of this.
        #expect(repo.read("README.md") == "hello\n")
        #expect(await Git.branchExists("main", in: repo.path))
    }

    // MARK: - Paths that can still lose work

    @Test("an ignored file the agent edited is destroyed without the report mentioning it")
    func ignoredFilesAreInvisibleToTheReport() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try repo.write(".gitignore", ".env\n")
        try await repo.commit("ignore env")
        try repo.write(".env", "APP_KEY=from-the-main-checkout\n")

        let manager = WorkspaceManager(store: try makeTestStore("archive"))
        let registered = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(repo: registered, prompt: "Edit the env")

        // Bloom itself copies `.env*` into every new worktree, so this is the file most likely to
        // exist there, and the agent editing it is the ordinary case rather than a contrived one.
        let worktree = TempRepo(existing: workspace.path)
        #expect(worktree.read(".env") == "APP_KEY=from-the-main-checkout\n")
        try worktree.write(".env", "APP_KEY=the-agent-worked-this-out\nQUEUE=redis\n")

        // `git status --porcelain` never lists ignored files and `git worktree remove`
        // deletes them silently. Bloom copies `.env*` into every worktree, so this was the
        // likeliest file to lose and the least likely to be missed until far too late.
        let report = try await manager.safetyReport(workspace: workspace, repo: registered)
        #expect(report.isSafeToDiscard == false, "an edited .env is work that exists nowhere else")

        // The assertion that survives the fix: either archiving refuses, or the file is still
        // there afterwards. Silently taking it is the one outcome that is not allowed.
        let refused: Bool
        do {
            try await manager.archive(workspace: workspace, repo: registered)
            refused = false
        } catch {
            refused = true
            #expect(
                refused || FileManager.default.fileExists(atPath: workspace.path + "/.env"),
                "archiving destroyed the edited .env without ever reporting it as a loss"
            )
        }
    }

    @Test("commits made on a detached HEAD in the worktree are invisible to the report")
    func detachedHeadCommitsAreInvisibleToTheReport() async throws {
        let (repo, registered, manager, workspace) = try await makeWorkspace()
        defer { repo.cleanUp() }

        // An agent that runs `git checkout` inside its worktree leaves HEAD detached. Commits it
        // then makes are on no branch at all, so counting commits on `workspace.branch` misses
        // them, and removing the worktree throws away the per-worktree reflog holding them.
        try await Shell.check("git", ["checkout", "-q", "--detach"], cwd: workspace.path)
        try TempRepo(existing: workspace.path).write("detached.txt", "work on no branch\n")
        try await commit(in: workspace.path, message: "detached work")
        let sha = try await Git.headSHA(of: workspace.path)

        // Reported as `detachedCommits` rather than `unpushedCommits`: these belong to no
        // branch at all, so counting them against the branch would be a lie about where
        // they live. What matters is that the report refuses to call the workspace safe.
        let report = try await manager.safetyReport(workspace: workspace, repo: registered)
        #expect(report.detachedCommits >= 1, "the detached commit exists nowhere else")
        #expect(report.isSafeToDiscard == false)

        let refused: Bool
        do {
            try await manager.archive(workspace: workspace, repo: registered)
            refused = false
        } catch {
            refused = true
        }

        let reachable = try await Shell.run("git", ["rev-list", "--all"], cwd: repo.path)
        #expect(
            refused || reachable.stdout.contains(sha),
            "archiving left the detached commit reachable from nothing"
        )
    }
}
