import Testing
import Foundation
@testable import BloomCore

/// The block of ten ports a workspace holds, and the fact that it is a column rather than a
/// property somebody's launch happens to be holding.
///
/// The number is not private to the app. A setup script writes it into a `.env`, a compose file
/// or a Valet site, and those files are still there tomorrow, so a block that changes between
/// launches is a dev server bound where nothing is looking. It is also the only thing that lets
/// an archive script take down what a setup script put up, since it is what makes `$BLOOM_PORT`
/// the same number in both.
@Suite("Workspace ports")
struct WorkspacePortTests {
    private func seed(
        _ store: Store, name: String = "w", port: Int = 0
    ) async throws -> (Repo, Workspace) {
        let repo = try await store.upsert(Repo(name: name, path: TestScratch.unique("repo")))
        var workspace = Workspace(
            repoID: repo.id, name: name, branch: "feature/\(name)",
            path: TestScratch.unique("worktree"), baseBranch: "main"
        )
        workspace.port = port
        return (repo, try await store.upsert(workspace))
    }

    /// The failure this column exists to prevent. The setup script wrote 3100 into a file on
    /// disk; the next launch must not hand the same workspace a different block.
    @Test("a workspace keeps its port across a restart")
    func aPortSurvivesARestart() async throws {
        let path = TestScratch.unique("port-restart") + ".sqlite"
        let store = try Store(path: path)
        let manager = WorkspaceManager(store: store)
        let (_, workspace) = try await seed(store)

        let allocated = await manager.ensurePort(for: workspace)
        #expect(allocated >= 3_100)

        // The next launch opens the same file.
        let relaunched = try Store(path: path)
        let stored = try #require(try await relaunched.workspace(id: workspace.id))
        #expect(stored.port == allocated)
        // And asking again does not move it, which is what the app does on every launch.
        #expect(await WorkspaceManager(store: relaunched).ensurePort(for: stored) == allocated)
    }

    /// The allocator probes live binds, so a workspace whose dev server is not running right now
    /// holds a block the probe would call free. On a fresh launch that is every workspace there
    /// is, which is exactly when this matters.
    @Test("allocation does not collide with a block another workspace already holds")
    func allocationAvoidsAStoredBlock() async throws {
        let store = try makeTestStore("port-collision")
        let manager = WorkspaceManager(store: store)
        let (_, held) = try await seed(store, name: "held", port: 3_100)
        let (_, asking) = try await seed(store, name: "asking")

        let allocated = await manager.ensurePort(for: asking)

        #expect(allocated != 0)
        let heldBlock = Set(held.port..<(held.port + PortAllocator.blockSize))
        let allocatedBlock = Set(allocated..<(allocated + PortAllocator.blockSize))
        #expect(heldBlock.isDisjoint(with: allocatedBlock))
    }

    /// Two panes of the same workspace can ask at once: a terminal being forked while a browser
    /// opens. They have to come away with one block, or the shell exports one number and the
    /// browser opens the other.
    @Test("two callers asking at once are given the same block")
    func concurrentCallersShareOneBlock() async throws {
        let store = try makeTestStore("port-race")
        let manager = WorkspaceManager(store: store)
        let (_, workspace) = try await seed(store)

        async let first = manager.ensurePort(for: workspace)
        async let second = manager.ensurePort(for: workspace)
        let (one, two) = await (first, second)

        #expect(one == two)
        #expect(try await store.workspace(id: workspace.id)?.port == one)
    }

    /// Every row that existed before this column did. Zero already means "no block yet" in the
    /// value and in `$BLOOM_PORT`, so there is nothing to backfill and nothing to guess at: the
    /// first caller that wants one allocates it, against the blocks the other rows hold.
    @Test("a row written before the column existed reads as holding no block, and can be given one")
    func anExistingDatabaseWithNoStoredPortStillAllocates() async throws {
        let path = TestScratch.unique("port-migration") + ".sqlite"
        let store = try Store(path: path)
        let (_, workspace) = try await seed(store, port: 4_200)

        // `ALTER TABLE` has no `IF NOT EXISTS`, and this is the shape the store's own tests use
        // to reproduce an old schema: replaying the step must neither throw nor reset the column.
        let raw = try SQLiteDatabase(path: path)
        raw.userVersion = 0

        let reopened = try Store(path: path)
        let stored = try #require(try await reopened.workspace(id: workspace.id))
        #expect(stored.port == 4_200)

        // And a row that never had one is not confused for a row holding block zero.
        let (_, fresh) = try await seed(reopened, name: "fresh")
        #expect(fresh.port == 0)
        let allocated = await WorkspaceManager(store: reopened).ensurePort(for: fresh)
        #expect(allocated != 0)
        #expect(!(4_200..<4_210).contains(allocated))
    }

    /// Archived workspaces are not counted against the free blocks. Their worktrees are gone and
    /// nothing is going to bind their block again, so holding it back forever would walk the
    /// allocator further up the range with every workspace that has ever existed.
    @Test("an archived workspace does not hold its block")
    func archivedWorkspacesReleaseTheirBlock() async throws {
        let store = try makeTestStore("port-archived")
        let manager = WorkspaceManager(store: store)
        let (_, gone) = try await seed(store, name: "gone", port: 3_100)
        try await store.update(workspaceID: gone.id) { $0.archive() }

        #expect(await manager.takenPorts(excluding: WorkspaceID("nobody")).isEmpty)
    }

    /// The port is a column like any other, so the rule the whole store is built on applies to it:
    /// a writer changes the columns it names and no others. The diff stat refresh runs against
    /// every row every six seconds and must not put a port back to zero.
    @Test("the other writers of a workspace row leave the port alone")
    func writersKeepThePort() async throws {
        let store = try makeTestStore("port-isolation")
        let manager = WorkspaceManager(store: store)
        let (_, workspace) = try await seed(store)
        let allocated = await manager.ensurePort(for: workspace)

        try await store.updateDiffStat(workspaceID: workspace.id, additions: 4, deletions: 1, files: 2)
        try await store.touch(workspaceID: workspace.id, unread: true)
        try await store.update(workspaceID: workspace.id) { $0.pinned = true }

        #expect(try await store.workspace(id: workspace.id)?.port == allocated)
    }
}
