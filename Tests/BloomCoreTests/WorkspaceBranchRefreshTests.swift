import Foundation
import Testing
@testable import BloomCore

@Suite("Refreshing an externally changed branch", .tags(.git, .destructive), .scratchDirectory)
struct WorkspaceBranchRefreshTests {
    private struct Fixture {
        let repo: TempRepo
        let store: Store
        let manager: WorkspaceManager
        let workspace: Workspace
    }

    private func fixture() async throws -> Fixture {
        let repo = try await TempRepo()
        let store = try makeTestStore("branch-refresh")
        let manager = WorkspaceManager(store: store)
        let registered = try await manager.addRepository(at: repo.path)
        let created = try await manager.createWorkspace(repo: registered, prompt: "Fix draft tickets")
        let workspace = try #require(try await store.workspace(id: created.id))
        return Fixture(repo: repo, store: store, manager: manager, workspace: workspace)
    }

    @Test("the regular diff refresh adopts an agent's branch rename")
    func renamedBranch() async throws {
        let fixture = try await fixture()
        defer { fixture.repo.cleanUp() }
        try await Git.renameBranch(fixture.workspace.branch, to: "add-delete-draft-tickets", in: fixture.workspace.path)

        await fixture.manager.refreshDiffStat(workspace: fixture.workspace)

        let saved = try #require(try await fixture.store.workspace(id: fixture.workspace.id))
        #expect(saved.branch == "add-delete-draft-tickets")
        #expect(saved.name == fixture.workspace.name)
        #expect(saved.path == fixture.workspace.path)
        #expect(saved.baseBranch == fixture.workspace.baseBranch)
        #expect(try await Git.currentBranch(of: saved.path) == saved.branch)
    }

    @Test("an unreadable diff base does not prevent the branch label updating")
    func missingBase() async throws {
        let fixture = try await fixture()
        defer { fixture.repo.cleanUp() }
        try await Git.renameBranch(fixture.workspace.branch, to: "renamed", in: fixture.workspace.path)
        let observed = try #require(try await fixture.store.update(workspaceID: fixture.workspace.id) {
            $0.baseBranch = "missing-base"
        })

        await fixture.manager.refreshDiffStat(workspace: observed)

        #expect(try await fixture.store.workspace(id: observed.id)?.branch == "renamed")
    }

    @Test("a detached HEAD keeps the last known branch")
    func detachedHead() async throws {
        let fixture = try await fixture()
        defer { fixture.repo.cleanUp() }
        try await Shell.check("git", ["checkout", "--detach", "HEAD"], cwd: fixture.workspace.path)

        await fixture.manager.refreshBranch(workspace: fixture.workspace)

        #expect(try await fixture.store.workspace(id: fixture.workspace.id)?.branch == fixture.workspace.branch)
    }

    @Test("checking out another branch does not transfer workspace ownership")
    func temporaryCheckout() async throws {
        let fixture = try await fixture()
        defer { fixture.repo.cleanUp() }
        try await Shell.check("git", ["checkout", "-b", "temporary-branch"], cwd: fixture.workspace.path)

        await fixture.manager.refreshBranch(workspace: fixture.workspace)

        #expect(try await fixture.store.workspace(id: fixture.workspace.id)?.branch == fixture.workspace.branch)
    }

    @Test("checking out the base never makes archive own it, even after deleting the old branch")
    func baseCheckout() async throws {
        let fixture = try await fixture()
        defer { fixture.repo.cleanUp() }
        try await Shell.check(
            "git", ["checkout", "--ignore-other-worktrees", "main"], cwd: fixture.workspace.path
        )
        await fixture.manager.refreshBranch(workspace: fixture.workspace)
        #expect(try await fixture.store.workspace(id: fixture.workspace.id)?.branch == fixture.workspace.branch)

        try await Git.deleteBranch(fixture.workspace.branch, in: fixture.workspace.path, force: true)
        await fixture.manager.refreshBranch(workspace: fixture.workspace)
        #expect(try await fixture.store.workspace(id: fixture.workspace.id)?.branch == fixture.workspace.branch)
    }

    @Test("the project default stays protected when this workspace uses a different base")
    func defaultCheckout() async throws {
        let fixture = try await fixture()
        defer { fixture.repo.cleanUp() }
        let observed = try #require(try await fixture.store.update(workspaceID: fixture.workspace.id) {
            $0.baseBranch = "another-base"
        })
        try await Shell.check(
            "git", ["checkout", "--ignore-other-worktrees", "main"], cwd: fixture.workspace.path
        )
        try await Git.deleteBranch(fixture.workspace.branch, in: fixture.workspace.path, force: true)

        await fixture.manager.refreshBranch(workspace: observed)
        try await fixture.store.updateCheckedOutBranch("main", observed: observed)

        #expect(try await fixture.store.workspace(id: observed.id)?.branch == fixture.workspace.branch)
    }

    @Test("a missing worktree never borrows the parent repository's branch")
    func missingWorktree() async throws {
        let fixture = try await fixture()
        defer { fixture.repo.cleanUp() }
        let observed = try #require(try await fixture.store.update(workspaceID: fixture.workspace.id) {
            $0.path = fixture.repo.path + "/missing-worktree"
        })

        await fixture.manager.refreshBranch(workspace: observed)

        #expect(try await fixture.store.workspace(id: observed.id)?.branch == fixture.workspace.branch)
    }

    @Test("an empty replacement directory cannot report its parent repository's branch")
    func nonRootDirectory() async throws {
        let fixture = try await fixture()
        defer { fixture.repo.cleanUp() }
        let path = fixture.repo.path + "/empty-worktree"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let observed = try #require(try await fixture.store.update(workspaceID: fixture.workspace.id) {
            $0.path = path
        })

        await fixture.manager.refreshBranch(workspace: observed)

        #expect(try await fixture.store.workspace(id: observed.id)?.branch == fixture.workspace.branch)
    }

    @Test("branch refresh preserves concurrent changes and the recorded pull request")
    func fieldIsolation() async throws {
        let fixture = try await fixture()
        defer { fixture.repo.cleanUp() }
        let latest = try #require(try await fixture.store.update(workspaceID: fixture.workspace.id) {
            $0.name = "My name"
            $0.pinned = true
            $0.unread = true
            $0.additions = 42
            $0.pullRequestNumber = 387
        })

        try await fixture.store.updateCheckedOutBranch("renamed", observed: fixture.workspace)

        let saved = try #require(try await fixture.store.workspace(id: fixture.workspace.id))
        #expect(saved == latest.with { $0.branch = "renamed" })
    }

    @Test("an old observation cannot undo a newer branch, archive or path change")
    func staleObservation() async throws {
        let fixture = try await fixture()
        defer { fixture.repo.cleanUp() }
        let changedBranch = try #require(try await fixture.store.update(workspaceID: fixture.workspace.id) {
            $0.branch = "newer-branch"
        })
        try await fixture.store.updateCheckedOutBranch("stale-branch", observed: fixture.workspace)
        #expect(try await fixture.store.workspace(id: fixture.workspace.id) == changedBranch)

        let moved = try #require(try await fixture.store.update(workspaceID: fixture.workspace.id) {
            $0.path += "/moved"
        })
        try await fixture.store.updateCheckedOutBranch("stale-branch", observed: changedBranch)
        #expect(try await fixture.store.workspace(id: fixture.workspace.id) == moved)

        try await fixture.store.update(workspaceID: fixture.workspace.id) {
            $0.archive()
        }
        let archived = try #require(try await fixture.store.workspace(id: fixture.workspace.id))
        try await fixture.store.updateCheckedOutBranch("stale-branch", observed: moved)
        #expect(try await fixture.store.workspace(id: fixture.workspace.id) == archived)
    }

    @Test("unchanged and invalid branch answers leave the stored workspace alone")
    func unchangedOrInvalid() async throws {
        let fixture = try await fixture()
        defer { fixture.repo.cleanUp() }
        for branch in [fixture.workspace.branch, "HEAD", "", "not a branch"] {
            try await fixture.store.updateCheckedOutBranch(branch, observed: fixture.workspace)
        }
        #expect(try await fixture.store.workspace(id: fixture.workspace.id) == fixture.workspace)
    }
}
