import Testing
import Foundation
@testable import BatonCore

/// `WorkspaceManager.restore` is what stands behind Edit > Undo after an archive, so the question
/// every test here asks is whether it really puts the workspace back, and whether it refuses in
/// every case where it could only pretend to.
@Suite("Restoring an archived workspace", .tags(.git, .destructive), .scratchDirectory)
struct WorkspaceRestoreTests {
    private func makeWorkspace(
        settings: String? = nil,
        prompt: String = "Restore a workspace"
    ) async throws -> (repo: TempRepo, registered: Repo, manager: WorkspaceManager, workspace: Workspace) {
        let repo = try await TempRepo()
        if let settings { try repo.write(".conductor/settings.toml", settings) }
        let manager = WorkspaceManager(store: try makeTestStore("restore"))
        let registered = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(repo: registered, prompt: prompt)
        return (repo, registered, manager, workspace)
    }

    private func commit(in worktree: String, message: String) async throws {
        try await Shell.check("git", ["add", "-A"], cwd: worktree)
        try await Shell.check("git", [
            "-c", "user.email=test@baton.local", "-c", "user.name=Baton Test",
            "-c", "commit.gpgsign=false", "commit", "-q", "-m", message,
        ], cwd: worktree)
    }

    // MARK: - The round trip

    @Test("an archived worktree comes back at the same path, on the same branch, at the same commit")
    func roundTrip() async throws {
        let (repo, registered, manager, workspace) = try await makeWorkspace()
        defer { repo.cleanUp() }

        try TempRepo(existing: workspace.path).write("feature.txt", "committed work\n")
        try await commit(in: workspace.path, message: "committed work")
        let sha = try await Git.headSHA(of: workspace.path)

        // Commits that exist on no other ref make `isSafeToDiscard` false, because deleting the
        // branch would strand them, so this is the archive the user confirms. Keeping the branch
        // strands nothing, which is what `isRestorableFromBranch` is for.
        let report = try await manager.safetyReport(workspace: workspace, repo: registered)
        #expect(report.isSafeToDiscard == false)
        #expect(report.isRestorableFromBranch)

        try await manager.archive(
            workspace: workspace, repo: registered, deleteBranch: false, force: true
        )
        #expect(FileManager.default.fileExists(atPath: workspace.path) == false)

        let restored = try await manager.restore(workspace: workspace, repo: registered)

        #expect(FileManager.default.fileExists(atPath: workspace.path))
        #expect(try await Git.currentBranch(of: workspace.path) == workspace.branch)
        #expect(try await Git.headSHA(of: workspace.path) == sha)
        #expect(TempRepo(existing: workspace.path).read("feature.txt") == "committed work\n")
        #expect(restored.state == .active)
        #expect(restored.archivedAt == nil)
        #expect(restored.path == workspace.path)
    }

    @Test("the stored workspace is active again, so the sidebar lists it")
    func theStoreAgreesTheWorkspaceIsBack() async throws {
        let (repo, registered, manager, workspace) = try await makeWorkspace()
        defer { repo.cleanUp() }

        try await manager.archive(workspace: workspace, repo: registered, deleteBranch: false)
        #expect(try await manager.store.workspaces().contains { $0.id == workspace.id } == false)

        try await manager.restore(workspace: workspace, repo: registered)
        #expect(try await manager.store.workspaces().contains { $0.id == workspace.id })
    }

    @Test("the copied files come back, because git never had them")
    func copiedFilesAreRestored() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try repo.write(".gitignore", ".env\n")
        try repo.write(".env", "TOKEN=from-the-checkout\n")
        try await repo.commit("ignore the env")

        let manager = WorkspaceManager(store: try makeTestStore("restore-copies"))
        let registered = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(repo: registered, prompt: "Copy the env")
        #expect(TempRepo(existing: workspace.path).read(".env") == "TOKEN=from-the-checkout\n")

        try await manager.archive(workspace: workspace, repo: registered, deleteBranch: false)
        try await manager.restore(workspace: workspace, repo: registered)

        #expect(TempRepo(existing: workspace.path).read(".env") == "TOKEN=from-the-checkout\n")
    }

    // MARK: - Refusals

    @Test("a workspace whose branch was deleted cannot be restored")
    func refusesWhenTheBranchIsGone() async throws {
        let (repo, registered, manager, workspace) = try await makeWorkspace()
        defer { repo.cleanUp() }

        try await manager.archive(workspace: workspace, repo: registered, deleteBranch: true)
        #expect(await manager.canRestore(workspace: workspace, repo: registered) == false)

        await #expect(throws: WorkspaceRestoreRefusal.self) {
            try await manager.restore(workspace: workspace, repo: registered)
        }
        #expect(FileManager.default.fileExists(atPath: workspace.path) == false)
    }

    @Test("a path that is occupied again is left alone")
    func refusesWhenSomethingIsAtThePath() async throws {
        let (repo, registered, manager, workspace) = try await makeWorkspace()
        defer { repo.cleanUp() }

        try await manager.archive(workspace: workspace, repo: registered, deleteBranch: false)
        try FileManager.default.createDirectory(
            atPath: workspace.path, withIntermediateDirectories: true
        )
        try TempRepo(existing: workspace.path).write("someone-elses.txt", "not ours\n")

        #expect(await manager.canRestore(workspace: workspace, repo: registered) == false)
        await #expect(throws: WorkspaceRestoreRefusal.self) {
            try await manager.restore(workspace: workspace, repo: registered)
        }
        #expect(TempRepo(existing: workspace.path).read("someone-elses.txt") == "not ours\n")
    }

    @Test("a live workspace is not restorable, because nothing was removed")
    func aLiveWorkspaceIsNotRestorable() async throws {
        let (repo, registered, manager, workspace) = try await makeWorkspace()
        defer { repo.cleanUp() }

        #expect(await manager.canRestore(workspace: workspace, repo: registered) == false)
    }

    @Test("an archive that kept the branch is restorable")
    func archiveKeepingTheBranchIsRestorable() async throws {
        let (repo, registered, manager, workspace) = try await makeWorkspace()
        defer { repo.cleanUp() }

        try await manager.archive(workspace: workspace, repo: registered, deleteBranch: false)
        #expect(await manager.canRestore(workspace: workspace, repo: registered))
    }

    // MARK: - What restoring does not claim

    @Test("uncommitted work is not restored, because nothing kept a copy of it")
    func uncommittedWorkStaysLost() async throws {
        let (repo, registered, manager, workspace) = try await makeWorkspace()
        defer { repo.cleanUp() }

        try TempRepo(existing: workspace.path).write("scratch.txt", "never committed\n")
        // The safety report is what stops this archive from being offered an undo in the app. It
        // is forced here to prove what the forced case really costs.
        try await manager.archive(
            workspace: workspace, repo: registered, deleteBranch: false, force: true
        )
        try await manager.restore(workspace: workspace, repo: registered)

        #expect(FileManager.default.fileExists(atPath: workspace.path))
        #expect(TempRepo(existing: workspace.path).exists("scratch.txt") == false)
    }

    // MARK: - What the report says about restorability

    @Test("commits on the branch do not stop a restore, because the branch still holds them")
    func commitsAreNotALoss() {
        let report = WorkspaceSafetyReport(unpushedCommits: 4)
        #expect(report.isSafeToDiscard == false)
        #expect(report.isRestorableFromBranch)
    }

    @Test("anything that lived only in the worktree stops a restore", arguments: [
        WorkspaceSafetyReport(hasUncommittedChanges: true),
        WorkspaceSafetyReport(untrackedFiles: ["notes.md"]),
        WorkspaceSafetyReport(modifiedIgnoredFiles: [".env"]),
        WorkspaceSafetyReport(detachedCommits: 2),
    ])
    func worktreeOnlyWorkBlocksARestore(report: WorkspaceSafetyReport) {
        #expect(report.isRestorableFromBranch == false)
    }

    @Test("an archive the report cleared outright is restorable")
    func aCleanReportIsRestorable() {
        let report = WorkspaceSafetyReport()
        #expect(report.isSafeToDiscard)
        #expect(report.isRestorableFromBranch)
    }
}
