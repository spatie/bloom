import Foundation
import Testing
@testable import BloomCore

/// The project's own checkout as a workspace. Every test here is the same question asked of a
/// different door: does anything Bloom does to a worktree it cut reach the owner's real checkout?
/// The archive script, the worktree removal, the branch delete, a rebuild on restore, a rename.
@Suite("Project checkout workspaces", .tags(.git, .destructive), .scratchDirectory)
struct ProjectCheckoutWorkspaceTests {
    private func makeProject(
        settings: String? = nil
    ) async throws -> (repo: TempRepo, registered: Repo, manager: WorkspaceManager) {
        let repo = try await TempRepo()
        if let settings { try repo.write(".bloom/settings.toml", settings) }
        let manager = WorkspaceManager(store: try makeTestStore("project-checkout"))
        let registered = try await manager.addRepository(at: repo.path)
        return (repo, registered, manager)
    }

    private func adopt(_ registered: Repo, _ manager: WorkspaceManager) async throws -> Workspace {
        try await manager.createWorkspace(
            repo: registered, prompt: "Work in place", kind: .projectCheckout
        )
    }

    // MARK: - Creating

    @Test("it is a row on the project's own folder, on its branch, with no worktree and no setup")
    func adoptsTheFolder() async throws {
        let (repo, registered, manager) = try await makeProject(settings: """
        [scripts]
        setup = 'touch "$BLOOM_ROOT_PATH/setup-ran"'
        """)
        defer { repo.cleanUp() }

        let workspace = try await adopt(registered, manager)

        #expect(workspace.kind == .projectCheckout)
        #expect(workspace.path == registered.path)
        #expect(workspace.branch == "main")
        #expect(workspace.baseBranch == "main")
        #expect(workspace.name == WorkspaceKind.projectCheckoutName)
        #expect(workspace.setupState == .skipped)
        #expect(try await Git.worktrees(of: repo.path).count == 1)
        #expect(!repo.exists("setup-ran"))
    }

    @Test("a worktree in the same project is still cut as before")
    func worktreesAreUntouched() async throws {
        let (repo, registered, manager) = try await makeProject()
        defer { repo.cleanUp() }

        let workspace = try await manager.createWorkspace(repo: registered, prompt: "Cut one")

        #expect(workspace.kind == .worktree)
        #expect(workspace.path != registered.path)
        #expect(try await Git.worktrees(of: repo.path).count == 2)
    }

    @Test("a project has one live project checkout, and a second create says which it is")
    func oneLiveCheckout() async throws {
        let (repo, registered, manager) = try await makeProject()
        defer { repo.cleanUp() }
        let first = try await adopt(registered, manager)

        let error = await #expect(throws: ProjectCheckoutTaken.self) {
            try await adopt(registered, manager)
        }
        #expect(error?.existing.id == first.id)
    }

    @Test("the database refuses a second live project checkout even past the check")
    func uniqueIndex() async throws {
        let (repo, registered, manager) = try await makeProject()
        defer { repo.cleanUp() }
        _ = try await adopt(registered, manager)

        let second = Workspace(
            repoID: registered.id, name: "Another", branch: "main", path: registered.path,
            baseBranch: "main", kind: .projectCheckout
        )
        await #expect(throws: (any Error).self) {
            try await manager.store.upsert(second)
        }
    }

    @Test("a detached head is refused rather than recorded as a branch called HEAD")
    func detachedHead() async throws {
        let (repo, registered, manager) = try await makeProject()
        defer { repo.cleanUp() }
        try await Shell.check("git", ["checkout", "-q", "--detach"], cwd: repo.path)

        await #expect(throws: ProjectCheckoutDetached.self) {
            try await adopt(registered, manager)
        }
    }

    @Test("start never asks the namer, so no placeholder can rename the branch")
    func neverNamedByAModel() async throws {
        let (repo, registered, manager) = try await makeProject()
        defer { repo.cleanUp() }

        let started = try await manager.start(
            WorkspaceStartRequest(
                repo: registered, prompt: "Fix the login", origin: .user,
                opensSession: false, setupPolicy: .run, kind: .projectCheckout
            ),
            namer: { "Coral Sea" }
        )

        #expect(started.placeholder == nil)
        #expect(started.setupSucceeded == nil)
        #expect(started.workspace.name == WorkspaceKind.projectCheckoutName)
    }

    // MARK: - Archiving

    @Test("archiving runs no script, removes nothing and deletes no branch", arguments: [false, true])
    func archiveTouchesNothing(force: Bool) async throws {
        let (repo, registered, manager) = try await makeProject(settings: """
        [git]
        delete_branch_on_archive = true
        [scripts]
        archive = 'touch "$BLOOM_ROOT_PATH/archive-script-ran"; exit 9'
        """)
        defer { repo.cleanUp() }
        let workspace = try await adopt(registered, manager)
        try repo.write("work.txt", "the owner's only copy\n")

        try await manager.archive(workspace: workspace, repo: registered, deleteBranch: true, force: force)

        #expect(try await manager.store.workspace(id: workspace.id)?.state == .archived)
        #expect(!repo.exists("archive-script-ran"))
        #expect(repo.read("work.txt") == "the owner's only copy\n")
        #expect(await Git.branchExists("main", in: repo.path))
        #expect(FileManager.default.fileExists(atPath: repo.path))
        let report = try await manager.safetyReport(workspace: workspace, repo: registered)
        #expect(report.preservedFolderPath == registered.path)
    }

    @Test("a worktree's archive script still runs, and still blocks when it fails")
    func worktreeArchiveStillRunsTheScript() async throws {
        let (repo, registered, manager) = try await makeProject(settings: """
        [scripts]
        archive = 'touch "$BLOOM_ROOT_PATH/archive-script-ran"; exit 9'
        """)
        defer { repo.cleanUp() }
        let worktree = try await manager.createWorkspace(repo: registered, prompt: "Cut one")

        await #expect(throws: (any Error).self) {
            try await manager.archive(workspace: worktree, repo: registered)
        }
        #expect(repo.exists("archive-script-ran"))
    }

    // MARK: - Restoring

    @Test("restoring brings the row back on the same folder and cuts no worktree")
    func restoreIsTheRowOnly() async throws {
        let (repo, registered, manager) = try await makeProject()
        defer { repo.cleanUp() }
        let workspace = try await adopt(registered, manager)
        try await manager.archive(workspace: workspace, repo: registered)
        let archived = try #require(try await manager.store.workspace(id: workspace.id))

        #expect(await manager.canRestore(workspace: archived, repo: registered) == false)
        #expect(await manager.restoreSource(workspace: archived, repo: registered) == .projectCheckout)
        let outcome = try await manager.restore(workspace: archived, repo: registered)

        #expect(outcome.workspace.state == .active)
        #expect(outcome.workspace.path == registered.path)
        #expect(outcome.relocatedFrom == nil)
        #expect(try await Git.worktrees(of: repo.path).count == 1)
    }

    @Test("restoring is refused while another project checkout is live")
    func restoreRefusedWhenTaken() async throws {
        let (repo, registered, manager) = try await makeProject()
        defer { repo.cleanUp() }
        let first = try await adopt(registered, manager)
        try await manager.archive(workspace: first, repo: registered)
        _ = try await adopt(registered, manager)
        let archived = try #require(try await manager.store.workspace(id: first.id))

        await #expect(throws: WorkspaceRestoreRefusal.self) {
            try await manager.restore(workspace: archived, repo: registered)
        }
        #expect(try await manager.store.workspace(id: first.id)?.state == .archived)
    }

    // MARK: - Following the folder

    @Test("the row follows the folder to another branch and back, base and all")
    func followsTheCheckout() async throws {
        let (repo, registered, manager) = try await makeProject()
        defer { repo.cleanUp() }
        let workspace = try await adopt(registered, manager)

        try await Shell.check("git", ["checkout", "-q", "-b", "feature"], cwd: repo.path)
        await manager.refreshBranch(workspace: workspace)
        let moved = try #require(try await manager.store.workspace(id: workspace.id))
        #expect(moved.branch == "feature")
        #expect(moved.baseBranch == "feature")

        try await Shell.check("git", ["checkout", "-q", "main"], cwd: repo.path)
        await manager.refreshBranch(workspace: moved)
        let back = try #require(try await manager.store.workspace(id: workspace.id))
        #expect(back.branch == "main")
        #expect(back.baseBranch == "main")
    }

    @Test("a detached head keeps the last branch")
    func detachedKeepsTheBranch() async throws {
        let (repo, registered, manager) = try await makeProject()
        defer { repo.cleanUp() }
        let workspace = try await adopt(registered, manager)
        try await Shell.check("git", ["checkout", "-q", "--detach"], cwd: repo.path)

        await manager.refreshBranch(workspace: workspace)

        #expect(try await manager.store.workspace(id: workspace.id)?.branch == "main")
    }

    // MARK: - Persistence

    @Test("the kind survives a read, an update and a whole-row upsert")
    func kindIsIdentity() async throws {
        let (repo, registered, manager) = try await makeProject()
        defer { repo.cleanUp() }
        let workspace = try await adopt(registered, manager)

        let renamed = try await manager.store.update(workspaceID: workspace.id) { $0.name = "Here" }
        #expect(renamed?.kind == .projectCheckout)

        var stale = workspace
        stale.kind = .worktree
        try await manager.store.upsert(stale)
        #expect(try await manager.store.workspace(id: workspace.id)?.kind == .projectCheckout)
    }
}

extension ProjectCheckoutWorkspaceTests {
    @Test("the first chat of a project checkout is not started on Bypass")
    func firstChatIsNotBypass() async throws {
        let (repo, registered, manager) = try await makeProject()
        defer { repo.cleanUp() }
        var controls = ComposerControls()
        controls.permissionMode = .bypassPermissions

        let started = try await manager.start(WorkspaceStartRequest(
            repo: registered, prompt: "Work in place", origin: .user, controls: controls,
            kind: .projectCheckout
        ))

        #expect(started.session?.permissionMode == .auto)
    }
}
