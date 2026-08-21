import Testing
import Foundation
import Synchronization
@testable import BloomCore

/// What the store says when it is written to.
///
/// The arc these tests hold up is Store to whoever is listening: a write happens, and the tables
/// it landed in are announced once the write has committed. Everything here goes through the real
/// `Store` and the real SQLite update hook, because the whole reason emission lives below `Store`
/// rather than beside its methods is that nobody has to remember to emit. A test that published by
/// hand would be testing the thing this design exists to avoid.
@Suite("Store change feed", .tags(.persistence), .scratchDirectory)
struct StoreObservationTests {

    // MARK: - What a write says

    @Test("a write names the table it landed in")
    func writeNamesItsTable() async throws {
        let store = try makeTestStore("changes")
        let listener = try await Listener(store)

        _ = try await store.upsert(Repo(name: "one", path: TestScratch.unique("repo")))

        #expect(await listener.nextBatch() == [.repos])
        listener.stop()
    }

    /// Every `upsert` in `Store` is an `INSERT ... ON CONFLICT(id) DO UPDATE`, so an existing row
    /// takes the `UPDATE` branch. The hook reports it as an update of the same table, which is
    /// what makes the domain right without `upsert` having to know which branch it took.
    @Test("an upsert over a row that already exists ticks the same domain")
    func upsertOverExistingRow() async throws {
        let store = try makeTestStore("changes")
        var repo = try await store.upsert(Repo(name: "one", path: TestScratch.unique("repo")))
        let listener = try await Listener(store)

        repo.name = "renamed"
        _ = try await store.upsert(repo)

        #expect(await listener.nextBatch() == [.repos])
        listener.stop()
    }

    /// A transaction is one change, not one per statement, and it is announced after it commits.
    @Test("a transaction is a single change, published after the commit")
    func transactionPublishesOnceAfterCommit() async throws {
        let store = try makeTestStore("changes")
        let database = try SQLiteDatabase(path: store.path)
        let listener = try await Listener(store)

        try database.transaction {
            try database.run(
                "INSERT INTO repos (id, name, path, created_at) VALUES (?, ?, ?, ?)",
                [.text("r1"), .text("one"), .text("/tmp/one"), .double(1)]
            )
            try database.run(
                """
                INSERT INTO workspaces (id, repo_id, name, branch, path, base_branch,
                    created_at, last_activity_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text("w1"), .text("r1"), .text("work"), .text("b"), .text("/tmp/w"),
                    .text("main"), .double(1), .double(1),
                ]
            )
        }

        #expect(await listener.nextBatch() == [.repos, .workspaces])
        #expect(await listener.nothingFurther())
        listener.stop()
    }

    /// The reason publishing waits for the commit rather than happening inside the hook.
    /// `Store.appendNext` rolls back and retries, up to sixteen times, whenever two writers collide
    /// on a sequence number, and a subscriber told about those attempts would go looking for rows
    /// that were never there.
    @Test("a transaction that rolls back says nothing")
    func rollbackPublishesNothing() async throws {
        let store = try makeTestStore("changes")
        let database = try SQLiteDatabase(path: store.path)
        let listener = try await Listener(store)

        struct Abandoned: Error {}
        #expect(throws: Abandoned.self) {
            try database.transaction {
                try database.run(
                    "INSERT INTO repos (id, name, path, created_at) VALUES (?, ?, ?, ?)",
                    [.text("r1"), .text("one"), .text("/tmp/one"), .double(1)]
                )
                throw Abandoned()
            }
        }

        #expect(await listener.nothingFurther())

        // And the abandoned write does not contaminate the next real one.
        _ = try await store.upsert(Repo(name: "two", path: TestScratch.unique("repo")))
        #expect(await listener.nextBatch() == [.repos])
        listener.stop()
    }

    /// A foreign key cascade is still a row change, so the child tables are announced too and
    /// `deleteRepo` needs no special handling to say what it took with it.
    @Test("a cascade delete ticks every table it emptied")
    func cascadeTicksChildTables() async throws {
        let store = try makeTestStore("changes")
        let repo = try await store.upsert(Repo(name: "one", path: TestScratch.unique("repo")))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "work", branch: "b",
            path: TestScratch.unique("worktree"), baseBranch: "main"
        ))
        let session = try await store.upsert(Session(workspaceID: workspace.id, title: "chat"))
        _ = try await store.appendNext(sessionID: session.id, kind: .user, payload: Data("hi".utf8))

        let listener = try await Listener(store)
        try await store.deleteRepo(id: repo.id)

        #expect(await listener.nextBatch() == [.repos, .workspaces, .sessions, .messages])
        listener.stop()
    }

    // MARK: - Coalescing

    /// The point of the pending set. A consumer that takes its time is not handed a queue of every
    /// write it missed, it is handed what has changed since it last looked, once.
    @Test("a slow consumer is given one merged batch, not one batch per write")
    func slowConsumerSeesMergedBatches() async throws {
        let store = try makeTestStore("changes")
        let repo = try await store.upsert(Repo(name: "one", path: TestScratch.unique("repo")))
        // Deliberately slow: long enough that every write below lands while the handler is busy.
        let listener = try await Listener(store, handlerDelay: .milliseconds(120))

        for index in 0..<20 {
            _ = try await store.upsert(Workspace(
                repoID: repo.id, name: "w\(index)", branch: "b\(index)",
                path: TestScratch.unique("worktree"), baseBranch: "main"
            ))
        }

        await waitUntil("the feed has gone quiet") { await listener.hasSettled(for: .milliseconds(400)) }
        let batches = listener.batches
        #expect(!batches.isEmpty, "twenty writes and the consumer heard nothing")
        #expect(batches.count < 20, "twenty writes produced \(batches.count) batches, so nothing merged")
        #expect(batches.allSatisfy { $0 == [.workspaces] })
        listener.stop()
    }

    /// Naming the domains at subscription time rather than filtering afterwards is what keeps a
    /// streaming turn out of the sidebar's business: `messages` is written many times a second for
    /// the whole of a turn, and a subscriber that does not read that table is never woken for it.
    @Test("a subscriber is not woken by a table it did not ask for")
    func interestFiltersAtTheSource() async throws {
        let store = try makeTestStore("changes")
        let repo = try await store.upsert(Repo(name: "one", path: TestScratch.unique("repo")))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "work", branch: "b",
            path: TestScratch.unique("worktree"), baseBranch: "main"
        ))
        let session = try await store.upsert(Session(workspaceID: workspace.id, title: "chat"))
        let listener = try await Listener(store, interest: [.repos, .workspaces])

        for index in 0..<10 {
            _ = try await store.appendNext(
                sessionID: session.id, kind: .assistantText, payload: Data("chunk \(index)".utf8)
            )
        }
        #expect(await listener.nothingFurther())

        _ = try await store.upsert(Repo(name: "two", path: TestScratch.unique("repo")))
        #expect(await listener.nextBatch() == [.repos])
        listener.stop()
    }

    // MARK: - Teardown

    @Test("cancelling the task iterating a feed takes the subscription with it")
    func cancellationUnsubscribes() async throws {
        let store = try makeTestStore("changes")
        let hub = store.changeHub
        let listener = try await Listener(store)
        #expect(hub.subscriberCount == 1)

        listener.stop()

        await waitUntil("the subscription is gone") { hub.subscriberCount == 0 }
    }

    // MARK: - One hub per file

    /// Bloom opens the same file twice in one process: the app's `Store`, and `IntentDatabase`'s
    /// for the App Intents. The update hook is per connection, so without a hub keyed on the file
    /// a workspace written through one of them would be invisible to a subscriber on the other.
    @Test("two connections on one file publish into the same feed")
    func twoConnectionsShareAHub() async throws {
        let store = try makeTestStore("changes")
        let listener = try await Listener(store)
        let second = try Store(path: store.path)

        _ = try await second.upsert(Repo(name: "one", path: TestScratch.unique("repo")))

        #expect(await listener.nextBatch() == [.repos])
        listener.stop()
    }

    /// Two in-memory databases are two databases with nothing in common, so sharing a hub between
    /// them would announce writes to rows the subscriber cannot read.
    @Test("in-memory stores each get a feed of their own")
    func inMemoryStoresDoNotShare() async throws {
        let first = try Store.inMemory()
        let second = try Store.inMemory()
        let listener = try await Listener(first)

        _ = try await second.upsert(Repo(name: "one", path: "/tmp/only-in-second"))
        #expect(await listener.nothingFurther())

        _ = try await first.upsert(Repo(name: "two", path: "/tmp/in-first"))
        #expect(await listener.nextBatch() == [.repos])
        listener.stop()
    }

    // MARK: - Writes that should not be changes at all

    /// SQLite does not care that an `UPDATE` writes the values that were already there: the row is
    /// rewritten and the hook fires. This is the fact that makes the compare in `updateDiffStat`
    /// below necessary rather than merely tidy, so it is pinned here.
    @Test("an update writing identical values still fires the hook")
    func identicalUpdateStillFires() async throws {
        let store = try makeTestStore("changes")
        let repo = try await store.upsert(Repo(name: "one", path: TestScratch.unique("repo")))
        let database = try SQLiteDatabase(path: store.path)
        let listener = try await Listener(store)

        try database.run("UPDATE repos SET name = name WHERE id = ?", [.text(repo.id)])

        #expect(await listener.nextBatch() == [.repos])
        listener.stop()
    }

    /// The diff stat refresh writes to every active workspace every six seconds. On an idle
    /// machine those three numbers have not moved, and before this compare each pass was a row
    /// rewritten, WAL churn, and a change announced to everything listening. An idle Bloom now
    /// says nothing at all.
    @Test("a diff stat that has not moved is not a write and not a change")
    func unchangedDiffStatIsSilent() async throws {
        let store = try makeTestStore("changes")
        let repo = try await store.upsert(Repo(name: "one", path: TestScratch.unique("repo")))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "work", branch: "b",
            path: TestScratch.unique("worktree"), baseBranch: "main"
        ))
        let listener = try await Listener(store)

        try await store.updateDiffStat(workspaceID: workspace.id, additions: 12, deletions: 3, files: 2)
        #expect(await listener.nextBatch() == [.workspaces])

        for _ in 0..<5 {
            try await store.updateDiffStat(
                workspaceID: workspace.id, additions: 12, deletions: 3, files: 2
            )
        }
        #expect(await listener.nothingFurther())

        // And a number that really did move is still a change.
        try await store.updateDiffStat(workspaceID: workspace.id, additions: 13, deletions: 3, files: 2)
        #expect(await listener.nextBatch() == [.workspaces])

        let reread = try await store.workspace(id: workspace.id)
        #expect(reread?.additions == 13)
        listener.stop()
    }

    /// The hook's one documented blind spot: `DELETE FROM t` with no `WHERE` drops the whole table
    /// without visiting a row, and the hook never fires. Enforcing foreign keys defeats that
    /// optimisation, and `SQLiteDatabase` turns them on. This is what would break if anybody ever
    /// decided that pragma was optional.
    @Test("a delete of every row still ticks, because foreign keys are on")
    func truncateOptimisationIsDefeated() async throws {
        let store = try makeTestStore("changes")
        let repo = try await store.upsert(Repo(name: "one", path: TestScratch.unique("repo")))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "work", branch: "b",
            path: TestScratch.unique("worktree"), baseBranch: "main"
        ))
        _ = try await store.upsert(ReviewComment(
            workspaceID: workspace.id,
            filePath: "a.swift",
            anchor: ReviewCommentAnchor(line: 1, text: "let a = 1"),
            body: "note"
        ))
        let database = try SQLiteDatabase(path: store.path)
        let listener = try await Listener(store)

        try database.run("DELETE FROM review_comments")

        #expect(await listener.nextBatch() == [.reviewComments])
        listener.stop()
    }
}

// MARK: - Support

/// One subscription, collected, so a test can assert on what was actually published.
///
/// Subscribing is asynchronous (it happens on the first `next` inside the task), so the
/// initialiser does not return until the hub has the subscriber registered. Without that wait a
/// test that writes immediately races the thing it is testing, and fails once in ten runs.
private final class Listener: Sendable {
    private struct State {
        var batches: [Set<StoreDomain>] = []
        var taken = 0
        var task: Task<Void, Never>?
    }

    private let state = Mutex(State())

    init(
        _ store: Store,
        interest: Set<StoreDomain> = Set(StoreDomain.allCases),
        handlerDelay: Duration? = nil
    ) async throws {
        let hub = store.changeHub
        let before = hub.subscriberCount
        let feed = store.changes(of: interest)
        let task = Task { [self] in
            for await batch in feed {
                state.withLock { $0.batches.append(batch) }
                if let handlerDelay { try? await Task.sleep(for: handlerDelay) }
            }
        }
        state.withLock { $0.task = task }
        await waitUntil("the listener has subscribed") { hub.subscriberCount > before }
    }

    var batches: [Set<StoreDomain>] {
        state.withLock { $0.batches }
    }

    /// The next batch this listener has not been shown yet, or nil if none arrives.
    func nextBatch(within timeout: Duration = .seconds(3)) async -> Set<StoreDomain>? {
        let seen = state.withLock { $0.taken }
        await waitUntil("a batch arrives", within: timeout) { self.batches.count > seen }
        return state.withLock { state in
            guard state.batches.count > seen else { return nil }
            state.taken = seen + 1
            return state.batches[seen]
        }
    }

    /// True when nothing further arrives in the time given. Deliberately a wait rather than an
    /// instant check: proving a negative here means giving the feed a chance to be wrong.
    func nothingFurther(within window: Duration = .milliseconds(250)) async -> Bool {
        let before = batches.count
        try? await Task.sleep(for: window)
        return batches.count == before
    }

    /// True once nothing has arrived for the window given.
    func hasSettled(for window: Duration) async -> Bool {
        await nothingFurther(within: window)
    }

    func stop() {
        state.withLock { $0.task }?.cancel()
    }

    deinit {
        state.withLock { $0.task }?.cancel()
    }
}
