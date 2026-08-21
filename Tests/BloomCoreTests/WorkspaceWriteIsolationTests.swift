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

    // MARK: - Who asked for the workspace

    /// The record of which agent asked for a workspace is the only thing standing between the
    /// bridge and letting anybody reach into anybody's worktree, and it is written once, at
    /// creation, and never again. Every other writer of this row runs afterwards and for the rest
    /// of the workspace's life. `update` picks a new column up on its own, which is exactly why
    /// this has to be a test: nothing in the code says out loud that these two columns are carried
    /// through, so nothing but this would notice a writer that stopped carrying them.
    @Test("the writers of a workspace row leave its parentage alone")
    func writersKeepTheOrigin() async throws {
        let store = try makeTestStore("isolation")
        let repo = try await store.upsert(Repo(name: "r", path: TestScratch.unique("repo")))
        let parent = try await seed(store)
        let started = try await store.upsert(Workspace(
            repoID: repo.id, name: "started", branch: "feature/started",
            path: TestScratch.unique("worktree"),
            baseBranch: "main",
            origin: .agent(parentWorkspaceID: parent.id, spawnToolUseID: "toolu_01")
        ))

        try await store.updateDiffStat(workspaceID: started.id, additions: 9, deletions: 1, files: 1)
        try await store.touch(workspaceID: started.id, unread: true)
        try await store.updateSetup(workspaceID: started.id, state: .succeeded, log: "done")
        try await store.update(workspaceID: started.id) { $0.name = "named by the model" }
        try await store.update(workspaceID: started.id) {
            $0.state = .archived
            $0.archivedAt = Date()
        }

        let stored = try #require(try await store.workspace(id: started.id))
        #expect(stored.origin == .agent(parentWorkspaceID: parent.id, spawnToolUseID: "toolu_01"))
        #expect(stored.name == "named by the model")
        #expect(stored.state == .archived)
    }

    /// And the owner's workspaces stay the owner's. A writer that filled the columns in with
    /// something rather than leaving them NULL would hand an agent authority over a worktree
    /// nobody gave it.
    @Test("a workspace the owner made never acquires a parent")
    func theOwnersWorkspacesStayTheOwners() async throws {
        let store = try makeTestStore("isolation")
        let workspace = try await seed(store)
        #expect(workspace.origin == .user)

        try await store.update(workspaceID: workspace.id) { $0.pinned = true }
        try await store.touch(workspaceID: workspace.id, unread: true)

        let stored = try #require(try await store.workspace(id: workspace.id))
        #expect(stored.origin == .user)
        #expect(stored.origin.isAgentSpawned == false)
    }

    /// Same bargain as the colour above: `ALTER TABLE` has no `IF NOT EXISTS`, and the suite
    /// rewinds `user_version` to reproduce an old schema.
    @Test("the parentage migration survives being replayed, and keeps what was stored")
    func theParentageMigrationReplays() async throws {
        let path = TestScratch.unique("parentage-replay") + ".sqlite"
        let store = try Store(path: path)
        let repo = try await store.upsert(Repo(name: "r", path: TestScratch.unique("repo")))
        let parent = try await store.upsert(Workspace(
            repoID: repo.id, name: "parent", branch: "b", path: TestScratch.unique("worktree"),
            baseBranch: "main"
        ))
        let started = try await store.upsert(Workspace(
            repoID: repo.id, name: "started", branch: "b2", path: TestScratch.unique("worktree"),
            baseBranch: "main",
            origin: .agent(parentWorkspaceID: parent.id, spawnToolUseID: "toolu_02")
        ))

        let raw = try SQLiteDatabase(path: path)
        raw.userVersion = 0

        let reopened = try Store(path: path)
        let storedParent = try #require(try await reopened.workspace(id: parent.id))
        let storedChild = try #require(try await reopened.workspace(id: started.id))
        #expect(storedParent.origin == .user)
        #expect(storedChild.origin == .agent(parentWorkspaceID: parent.id, spawnToolUseID: "toolu_02"))
    }
}

/// Counting, listing and recognising the workspaces an agent asked for.
@Suite("Workspaces an agent started", .tags(.persistence), .scratchDirectory)
struct WorkspaceParentageTests {
    private func seed(_ store: Store) async throws -> Repo {
        try await store.upsert(Repo(name: "r", path: TestScratch.unique("repo")))
    }

    private func makeWorkspace(
        _ store: Store, repo: Repo, name: String, origin: WorkspaceOrigin = .user
    ) async throws -> Workspace {
        try await store.upsert(Workspace(
            repoID: repo.id, name: name, branch: "feature/\(name)",
            path: TestScratch.unique("worktree"), baseBranch: "main", origin: origin
        ))
    }

    @Test("the list of what an agent started leaves out what it archived")
    func listsTheLiveOnes() async throws {
        let store = try makeTestStore("parentage")
        let repo = try await seed(store)
        let parent = try await makeWorkspace(store, repo: repo, name: "parent")
        let first = try await makeWorkspace(
            store, repo: repo, name: "first",
            origin: .agent(parentWorkspaceID: parent.id, spawnToolUseID: "toolu_a")
        )
        let second = try await makeWorkspace(
            store, repo: repo, name: "second",
            origin: .agent(parentWorkspaceID: parent.id, spawnToolUseID: "toolu_b")
        )
        _ = try await makeWorkspace(store, repo: repo, name: "unrelated")

        try await store.update(workspaceID: second.id) { $0.state = .archived }

        let live = try await store.workspaces(startedBy: parent.id)
        #expect(live.map(\.id) == [first.id])

        let all = try await store.workspaces(startedBy: parent.id, includeArchived: true)
        #expect(Set(all.map(\.id)) == [first.id, second.id])
    }

    /// The one that matters. An allowance archiving hands back is an allowance that never runs
    /// out: start, archive, start again, for ever, and every round of it cuts a worktree and
    /// spends whatever the agent in it spends.
    @Test("archiving does not refund an agent its budget")
    func archivingDoesNotRefundTheBudget() async throws {
        let store = try makeTestStore("parentage")
        let repo = try await seed(store)
        let parent = try await makeWorkspace(store, repo: repo, name: "parent")

        for index in 0..<3 {
            let started = try await makeWorkspace(
                store, repo: repo, name: "started\(index)",
                origin: .agent(parentWorkspaceID: parent.id, spawnToolUseID: "toolu_\(index)")
            )
            try await store.update(workspaceID: started.id) {
                $0.state = .archived
                $0.archivedAt = Date()
            }
        }

        #expect(try await store.workspaces(startedBy: parent.id).isEmpty)
        #expect(try await store.countWorkspaces(startedBy: parent.id) == 3)
    }

    /// A parent that has been archived, or removed outright, leaves a parent id pointing at
    /// nothing. That is on purpose: the record of who asked has to outlive the asker. What it must
    /// not do is read as the owner's, because the owner did not ask for it.
    @Test("a workspace keeps its parentage after the parent is gone")
    func parentageOutlivesTheParent() async throws {
        let store = try makeTestStore("parentage")
        let repo = try await seed(store)
        let parent = try await makeWorkspace(store, repo: repo, name: "parent")
        let started = try await makeWorkspace(
            store, repo: repo, name: "started",
            origin: .agent(parentWorkspaceID: parent.id, spawnToolUseID: "toolu_c")
        )

        try await store.deleteWorkspace(id: parent.id)

        let stored = try #require(try await store.workspace(id: started.id))
        #expect(stored.origin == .agent(parentWorkspaceID: parent.id, spawnToolUseID: "toolu_c"))
        #expect(try await store.workspace(id: parent.id) == nil)
    }

    /// What a retried spawn asks before it cuts anything.
    @Test("a tool call can find what it already made")
    func aToolCallFindsWhatItMade() async throws {
        let store = try makeTestStore("parentage")
        let repo = try await seed(store)
        let parent = try await makeWorkspace(store, repo: repo, name: "parent")
        let started = try await makeWorkspace(
            store, repo: repo, name: "started",
            origin: .agent(parentWorkspaceID: parent.id, spawnToolUseID: "toolu_d")
        )
        try await store.update(workspaceID: started.id) { $0.state = .archived }

        #expect(try await store.workspaces(spawnToolUseID: "toolu_d").map(\.id) == [started.id])
        #expect(try await store.workspaces(spawnToolUseID: "toolu_none").isEmpty)
    }

    /// Half a record is not half an agent spawn, it is a row nobody can vouch for, and the only
    /// thing parentage grants is authority. So it reads as the owner's.
    @Test("a parent id with no tool call beside it grants nothing")
    func halfARecordGrantsNothing() async throws {
        #expect(WorkspaceOrigin(parentWorkspaceID: "w1", spawnToolUseID: nil) == .user)
        #expect(WorkspaceOrigin(parentWorkspaceID: nil, spawnToolUseID: "toolu_e") == .user)
        #expect(WorkspaceOrigin(parentWorkspaceID: "", spawnToolUseID: "toolu_e") == .user)
        #expect(
            WorkspaceOrigin(parentWorkspaceID: "w1", spawnToolUseID: "toolu_e")
                == .agent(parentWorkspaceID: "w1", spawnToolUseID: "toolu_e")
        )
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
