import Testing
import Foundation
@testable import BloomCore

/// What a writer of the `workspaces` table is allowed to change, and what it must leave alone.
///
/// A workspace row has many writers and they run at wildly different speeds. The diff stat
/// refresh writes to every row every six seconds. A finishing turn writes `last_activity_at` and
/// `unread`. A setup script writes its outcome minutes after it started. An archive writes
/// `state` at the end of a safety report, an archive script, a worktree removal and a branch
/// delete. Automatic naming writes a name whenever the model answers.
///
/// Each of those used to send a whole `Workspace` value it had read at some earlier moment, so
/// whichever of them wrote last put every column back to what it had seen. Mostly that is a stale
/// number that heals on the next pass. For `state` it is not: a workspace archived and then
/// written over by a pin is a row that says the workspace is live, with no worktree behind it,
/// and it still says so after a relaunch.
///
/// So the rule these tests hold to is: a write changes the columns it names and no others.
@Suite("Workspace write isolation", .tags(.persistence), .scratchDirectory)
struct WorkspaceWriteIsolationTests {
    private func seed(_ store: Store) async throws -> Workspace {
        let repo = try await store.upsert(Repo(name: "r", path: TestScratch.unique("repo")))
        return try await store.upsert(Workspace(
            repoID: repo.id, name: "original", branch: "feature/original",
            path: TestScratch.unique("worktree"), baseBranch: "main"
        ))
    }

    // MARK: - The contract

    /// The three narrow writers that already existed all run between a caller's read and its
    /// write in ordinary use. None of them may be undone by it.
    @Test("a write leaves alone every column it did not name")
    func writeTouchesOnlyWhatItNames() async throws {
        let store = try makeTestStore("isolation")
        let workspace = try await seed(store)

        // Everything below happens after the caller's copy was read.
        try await store.updateDiffStat(workspaceID: workspace.id, additions: 12, deletions: 3, files: 2)
        try await store.touch(workspaceID: workspace.id, unread: true)
        try await store.updateSetup(workspaceID: workspace.id, state: .succeeded, log: "done")

        try await store.update(workspaceID: workspace.id) { $0.pinned = true }

        let stored = try #require(try await store.workspace(id: workspace.id))
        #expect(stored.pinned)
        #expect(stored.additions == 12)
        #expect(stored.deletions == 3)
        #expect(stored.changedFiles == 2)
        #expect(stored.unread)
        #expect(stored.setupState == .succeeded)
        #expect(stored.setupLog == "done")
        #expect(stored.lastActivityAt > workspace.lastActivityAt)
    }

    /// The state a stale write used to destroy, in the sequence that destroys it: the archive
    /// finishes, and the pin the sidebar was already holding lands afterwards.
    @Test("pinning a workspace cannot bring it back from archived")
    func pinCannotUnarchive() async throws {
        let store = try makeTestStore("isolation")
        let workspace = try await seed(store)

        try await store.update(workspaceID: workspace.id) {
            $0.state = .archived
            $0.archivedAt = Date()
        }
        // The sidebar is still holding the row as it was before the archive, and the user pins it.
        try await store.update(workspaceID: workspace.id) { $0.pinned.toggle() }

        let stored = try #require(try await store.workspace(id: workspace.id))
        #expect(stored.state == .archived)
        #expect(stored.archivedAt != nil)
        #expect(stored.pinned)
        #expect(try await store.workspaces().isEmpty)
    }

    /// Toggling reads the stored value rather than the caller's, so two presses in the same second
    /// cannot both decide the workspace is pinned.
    @Test("a toggle is against the stored value, not against the caller's copy")
    func toggleIsAgainstTheStoredValue() async throws {
        let store = try makeTestStore("isolation")
        let workspace = try await seed(store)

        try await store.update(workspaceID: workspace.id) { $0.pinned.toggle() }
        try await store.update(workspaceID: workspace.id) { $0.pinned.toggle() }

        #expect(try await store.workspace(id: workspace.id)?.pinned == false)
    }

    /// An `upsert` would insert the row again. A workspace whose project was removed while
    /// something was writing to it must stay removed.
    @Test("a targeted write does not recreate a workspace that is gone")
    func doesNotRecreateADeletedWorkspace() async throws {
        let store = try makeTestStore("isolation")
        let workspace = try await seed(store)
        try await store.deleteWorkspace(id: workspace.id)

        let result = try await store.update(workspaceID: workspace.id) { $0.name = "back from the dead" }

        #expect(result == nil)
        #expect(try await store.workspaces(includeArchived: true).isEmpty)
    }

    /// Identity is not the caller's to move, whatever the closure does with it.
    @Test("a write cannot change which workspace it is or which project it belongs to")
    func cannotChangeIdentity() async throws {
        let store = try makeTestStore("isolation")
        let workspace = try await seed(store)
        let other = try await store.upsert(Repo(name: "other", path: TestScratch.unique("other")))

        try await store.update(workspaceID: workspace.id) {
            $0.id = "some-other-id"
            $0.repoID = other.id
            $0.name = "renamed"
        }

        let stored = try #require(try await store.workspace(id: workspace.id))
        #expect(stored.id == workspace.id)
        #expect(stored.repoID == workspace.repoID)
        #expect(stored.name == "renamed")
        #expect(try await store.workspaces(repoID: other.id).isEmpty)
    }

    // MARK: - The marks a person sets by hand

    /// Both marks go through `update`, so both have to leave everything else alone. The colour is
    /// the newest column on this table and the one most likely to be written from a menu that has
    /// been sitting open while an agent worked.
    @Test("marking a workspace unread, and colouring it, touch nothing else")
    func theHandMarksTouchNothingElse() async throws {
        let store = try makeTestStore("marks")
        let workspace = try await seed(store)

        try await store.updateDiffStat(workspaceID: workspace.id, additions: 4, deletions: 1, files: 1)
        try await store.update(workspaceID: workspace.id) { $0.pinned = true }

        // Everything below happens after a menu was opened on the row above.
        try await store.update(workspaceID: workspace.id) { $0.unread = true }
        try await store.update(workspaceID: workspace.id) { $0.colour = "22A06B" }

        let stored = try #require(try await store.workspace(id: workspace.id))
        #expect(stored.unread)
        #expect(stored.colour == "22A06B")
        #expect(stored.pinned)
        #expect(stored.additions == 4)
        #expect(stored.name == "original")

        // And taking the colour off is a write like any other, not a row rebuilt without it.
        try await store.update(workspaceID: workspace.id) { $0.colour = nil }
        let cleared = try #require(try await store.workspace(id: workspace.id))
        #expect(cleared.colour == nil)
        #expect(cleared.unread)
        #expect(cleared.pinned)
    }

    /// The colour arrived in a migration, and `ALTER TABLE` has no `IF NOT EXISTS`. The store's
    /// own tests rewind `user_version` to reproduce an old schema, so a step that could not be
    /// replayed would throw and take the whole migration transaction with it.
    @Test("the colour migration survives being replayed, and keeps what was stored")
    func theColourMigrationReplays() async throws {
        let path = TestScratch.unique("colour-replay") + ".sqlite"
        let store = try Store(path: path)
        let repo = try await store.upsert(Repo(name: "r", path: TestScratch.unique("repo")))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "w", branch: "b", path: TestScratch.unique("worktree"),
            baseBranch: "main"
        ))
        try await store.update(workspaceID: workspace.id) { $0.colour = "D8608C" }

        let raw = try SQLiteDatabase(path: path)
        raw.userVersion = 0

        let reopened = try Store(path: path)
        let stored = try #require(try await reopened.workspace(id: workspace.id))
        // Replaying must not put the column back to its default either.
        #expect(stored.colour == "D8608C")
    }
}

/// The same rule, through the callers that carry it, with a real git repository underneath.
///
/// These are the ones that were wrong. Each of them reads a `Workspace`, does something slow with
/// git, and writes the result, and until now that write was the whole value.
@Suite("Workspace write isolation through git", .tags(.git, .destructive), .scratchDirectory)
struct WorkspaceWriteIsolationGitTests {
    private func makeWorkspace() async throws
    -> (repo: TempRepo, registered: Repo, manager: WorkspaceManager, store: Store, workspace: Workspace) {
        let repo = try await TempRepo()
        let store = try makeTestStore("isolation-git")
        let manager = WorkspaceManager(store: store)
        let registered = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(repo: registered, prompt: "Write isolation")
        return (repo, registered, manager, store, workspace)
    }

    /// `WorkspaceManager.archive` is handed the workspace as the caller last saw it, and only gets
    /// to the write after the safety report, the archive script, `git worktree remove` and the
    /// branch delete. Automatic naming answering inside that window is ordinary, and used to be
    /// erased by it.
    @Test("an archive does not undo a rename that landed while it ran")
    func archiveKeepsAConcurrentRename() async throws {
        let (repo, registered, manager, store, workspace) = try await makeWorkspace()
        defer { repo.cleanUp() }

        // The model answered while the archive was running.
        try await store.update(workspaceID: workspace.id) { $0.name = "named by the model" }

        try await manager.archive(workspace: workspace, repo: registered, deleteBranch: false)

        let stored = try #require(try await store.workspace(id: workspace.id))
        #expect(stored.name == "named by the model")
        #expect(stored.state == .archived)
    }

    /// The same for the numbers, which the refresh writes to every row every six seconds, and for
    /// the mark that says a turn finished while you were not looking.
    @Test("an archive does not undo the diff stats and the unread mark")
    func archiveKeepsConcurrentActivity() async throws {
        let (repo, registered, manager, store, workspace) = try await makeWorkspace()
        defer { repo.cleanUp() }

        try await store.updateDiffStat(workspaceID: workspace.id, additions: 40, deletions: 1, files: 3)
        try await store.touch(workspaceID: workspace.id, unread: true)

        try await manager.archive(workspace: workspace, repo: registered, deleteBranch: false)

        let stored = try #require(try await store.workspace(id: workspace.id))
        #expect(stored.additions == 40)
        #expect(stored.unread)
        #expect(stored.state == .archived)
    }

    /// The one that does not heal. Everything above is a wrong number until the next pass; this is
    /// a row that outlives the process, with no worktree behind it.
    @Test("a workspace archived while its row moved on is still archived after a relaunch")
    func archiveSurvivesARelaunch() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        let path = TestScratch.unique("relaunch") + ".sqlite"
        let store = try Store(path: path)
        let manager = WorkspaceManager(store: store)
        let registered = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(repo: registered, prompt: "Relaunch")

        // Anything at all writing to the row between the caller's read and the archive's write.
        try await store.update(workspaceID: workspace.id) { $0.pinned = true }

        try await manager.archive(workspace: workspace, repo: registered, deleteBranch: false)

        // The next launch opens the same file.
        let relaunched = try Store(path: path)
        let stored = try #require(try await relaunched.workspace(id: workspace.id))
        #expect(stored.state == .archived)
        #expect(stored.archivedAt != nil)
        #expect(try await relaunched.workspaces().isEmpty)
        // And the row is not describing a worktree that is there, because it is not.
        #expect(FileManager.default.fileExists(atPath: stored.path) == false)
    }

    /// Continuing on a new branch is handed the workspace as the caller last saw it and writes
    /// after `git checkout -b`. The name the model settled on is not its to revert.
    @Test("continuing on a new branch does not undo a rename that landed while it ran")
    func continuationKeepsAConcurrentRename() async throws {
        let (repo, _, manager, store, workspace) = try await makeWorkspace()
        defer { repo.cleanUp() }

        try await store.update(workspaceID: workspace.id) { $0.name = "named by the model" }

        let continuation = try await manager.continueOnNewBranch(
            workspace: workspace, branch: "feature/next"
        )

        #expect(continuation.branch == "feature/next")
        let stored = try #require(try await store.workspace(id: workspace.id))
        #expect(stored.name == "named by the model")
        #expect(stored.branch == "feature/next")
    }

    /// A restore rebuilds the worktree first, which is a `git worktree add` and a file copy, and
    /// only then writes. A turn finishing in that window is not the restore's to undo.
    @Test("a restore does not undo a turn that finished while the worktree was rebuilt")
    func restoreKeepsConcurrentActivity() async throws {
        let (repo, registered, manager, store, workspace) = try await makeWorkspace()
        defer { repo.cleanUp() }

        try await manager.archive(workspace: workspace, repo: registered, deleteBranch: false)
        let archived = try #require(try await store.workspace(id: workspace.id))

        // Between the caller reading the archived row and the restore writing its result.
        try await store.updateDiffStat(workspaceID: workspace.id, additions: 7, deletions: 2, files: 1)
        try await store.touch(workspaceID: workspace.id, unread: true)

        try await manager.restore(workspace: archived, repo: registered)

        let stored = try #require(try await store.workspace(id: workspace.id))
        #expect(stored.state == .active)
        #expect(stored.archivedAt == nil)
        #expect(stored.additions == 7)
        #expect(stored.unread)
    }
}
