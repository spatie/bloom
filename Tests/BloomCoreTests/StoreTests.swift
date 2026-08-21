import Testing
import Foundation
@testable import BloomCore

@Suite("Store", .tags(.persistence), .scratchDirectory)
struct StoreTests {
    @Test("round-trips a repo")
    func roundTripsRepo() async throws {
        let store = try makeTestStore("store")
        let repo = Repo(name: "there-there", path: "/tmp/there-there", defaultBranch: "main")
        try await store.upsert(repo)

        let loaded = try await store.repos()
        #expect(loaded.count == 1)
        #expect(loaded[0].name == "there-there")
        #expect(loaded[0].defaultBranch == "main")
        #expect(try await store.repo(path: "/tmp/there-there")?.id == repo.id)
    }

    @Test("updates a repo on conflicting id")
    func updatesRepo() async throws {
        let store = try makeTestStore("store")
        var repo = Repo(name: "old", path: "/tmp/x")
        try await store.upsert(repo)
        repo.name = "new"
        try await store.upsert(repo)

        #expect(try await store.repos().count == 1)
        #expect(try await store.repos()[0].name == "new")
    }

    @Test("cascades workspace deletion from its repo")
    func cascadesDelete() async throws {
        let store = try makeTestStore("store")
        let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r"))
        try await store.upsert(Workspace(
            repoID: repo.id, name: "w", branch: "b", path: "/tmp/r-w", baseBranch: "main"
        ))
        #expect(try await store.workspaces().count == 1)

        try await store.deleteRepo(id: repo.id)
        #expect(try await store.workspaces().isEmpty)
    }

    @Test("hides archived workspaces unless asked")
    func hidesArchived() async throws {
        let store = try makeTestStore("store")
        let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r"))
        var workspace = Workspace(repoID: repo.id, name: "w", branch: "b", path: "/p", baseBranch: "main")
        try await store.upsert(workspace)
        workspace.archive()
        workspace.archivedAt = Date()
        try await store.upsert(workspace)

        #expect(try await store.workspaces().isEmpty)
        #expect(try await store.workspaces(includeArchived: true).count == 1)
        #expect(try await store.workspace(id: workspace.id)?.archivedAt != nil)
    }

    @Test("appends messages with increasing sequence numbers")
    func appendsMessages() async throws {
        let store = try makeTestStore("store")
        let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "w", branch: "b", path: "/p", baseBranch: "main"
        ))
        let session = try await store.upsert(Session(workspaceID: workspace.id))

        for index in 0..<5 {
            let seq = try await store.nextSeq(sessionID: session.id)
            #expect(seq == index)
            try await store.append(Message(
                sessionID: session.id, seq: seq, kind: .assistantText,
                payload: Data("body \(index)".utf8)
            ))
        }

        let messages = try await store.messages(sessionID: session.id)
        #expect(messages.count == 5)
        #expect(messages.map(\.seq) == [0, 1, 2, 3, 4])
        #expect(String(decoding: messages[3].payload, as: UTF8.self) == "body 3")
        #expect(try await store.messages(sessionID: session.id, afterSeq: 2).count == 2)
    }

    @Test("finds a tool use row by its reference id")
    func findsByRefID() async throws {
        let store = try makeTestStore("store")
        let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "w", branch: "b", path: "/p", baseBranch: "main"
        ))
        let session = try await store.upsert(Session(workspaceID: workspace.id))

        try await store.append(Message(
            sessionID: session.id, seq: 0, kind: .toolUse,
            payload: Data("{}".utf8), refID: "toolu_123"
        ))

        let found = try await store.message(sessionID: session.id, refID: "toolu_123")
        #expect(found?.kind == .toolUse)
        #expect(try await store.message(sessionID: session.id, refID: "nope") == nil)
    }

    @Test("stores and clears drafts")
    func storesDrafts() async throws {
        let store = try makeTestStore("store")
        try await store.saveDraft(sessionID: "s1", body: "hello")
        #expect(try await store.draft(sessionID: "s1") == "hello")
        try await store.saveDraft(sessionID: "s1", body: "")
        #expect(try await store.draft(sessionID: "s1") == "")
    }

    @Test("reorders a workspace's sessions without touching what the runner owns")
    func reordersSessions() async throws {
        let store = try makeTestStore("store")
        let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "w", branch: "b", path: "/p", baseBranch: "main"
        ))
        var first = Session(workspaceID: workspace.id, title: "first", sortOrder: 0)
        first.agentSessionID = "agent-1"
        let second = Session(workspaceID: workspace.id, title: "second", sortOrder: 1)
        let third = Session(workspaceID: workspace.id, title: "third", sortOrder: 2)
        for session in [first, second, third] { try await store.upsert(session) }

        try await store.reorderSessions(ids: [third.id, first.id, second.id])

        let ordered = try await store.sessions(workspaceID: workspace.id)
        #expect(ordered.map(\.title) == ["third", "first", "second"])
        // Resume depends on this column, and a reorder written as a whole row would drop it.
        #expect(try await store.session(id: first.id)?.agentSessionID == "agent-1")
    }

    @Test("resets sessions that were running when the app died")
    func resetsRunningSessions() async throws {
        let store = try makeTestStore("store")
        let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "w", branch: "b", path: "/p", baseBranch: "main"
        ))
        var session = Session(workspaceID: workspace.id)
        session.state = .running
        try await store.upsert(session)

        try await store.resetRunningSessions()
        #expect(try await store.session(id: session.id)?.state == .idle)
    }

    /// Commit d81efda. `waiting` is the half that needed saying: a blocked agent holds its turn
    /// open until it is answered, so a session left there came back drawing a raised hand over a
    /// process that had been gone since the last launch.
    ///
    /// Driven off `SessionLifecycle` rather than off a list written here, so this asserts the
    /// thing that actually matters: the bulk pass touches exactly the rows the table moves, and
    /// leaves exactly the rows it does not. Add a state to `SessionState` and this covers it.
    @Test("the launch pass clears exactly what the table says a relaunch clears",
          arguments: SessionState.allCases)
    func relaunchPassFollowsTheTable(state: SessionState) async throws {
        let store = try makeTestStore("store")
        let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "w", branch: "b", path: "/p", baseBranch: "main"
        ))
        var session = Session(workspaceID: workspace.id)
        session.state = state
        try await store.upsert(session)

        try await store.resetRunningSessions()

        let expected = state.transition(on: .appRelaunched).destination ?? state
        #expect(try await store.session(id: session.id)?.state == expected)
    }

    /// The same property one table over. `recoverInterruptedSetups` is one statement over every
    /// affected row because it runs before a window exists, and the price of that is that it could
    /// become a second opinion. It asks `SetupLifecycle` which states to select and where to send
    /// them, and this is what holds it to that.
    @Test("the launch pass recovers exactly what the table says an interruption recovers",
          arguments: SetupState.allCases)
    func setupRecoveryPassFollowsTheTable(state: SetupState) async throws {
        let store = try makeTestStore("store")
        let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "w", branch: "b", path: "/p", baseBranch: "main",
            setupState: state, setupLog: "the original log"
        ))

        try await store.recoverInterruptedSetups()

        let outcome = state.transition(on: .runInterrupted)
        let stored = try #require(try await store.workspace(id: workspace.id))
        #expect(stored.setupState == (outcome.destination ?? state))
        // The note is the event's own, so the SQL and `Workspace.apply` cannot come to describe the
        // same interruption in two different sentences.
        let note = try #require(SetupEvent.runInterrupted.note)
        #expect(stored.setupLog.contains(note) == outcome.moves)
    }

    @Test("reconciles a setup that was still running when the app died")
    func recoversInterruptedSetup() async throws {
        let store = try makeTestStore("store")
        let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "w", branch: "b", path: "/p", baseBranch: "main",
            setupState: .running, setupLog: "installing dependencies"
        ))

        try await store.recoverInterruptedSetups()

        let stored = try #require(try await store.workspace(id: workspace.id))
        #expect(stored.setupState == .pending)
        // What the script did manage to print is evidence, so it stays, and the note goes after it
        // so an interrupted run cannot be mistaken for a script that failed on its own.
        #expect(stored.setupLog.hasPrefix("installing dependencies"))
        #expect(stored.setupLog.contains("interrupted"))
    }

    @Test(
        "leaves a setup state that is not running alone",
        arguments: [SetupState.pending, .succeeded, .failed, .skipped]
    )
    func leavesSettledSetupStatesAlone(state: SetupState) async throws {
        let store = try makeTestStore("store")
        let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "w", branch: "b", path: "/p", baseBranch: "main",
            setupState: state, setupLog: "the original log"
        ))

        try await store.recoverInterruptedSetups()

        let stored = try #require(try await store.workspace(id: workspace.id))
        #expect(stored.setupState == state)
        #expect(stored.setupLog == "the original log")
    }

    @Test("writes the setup columns without clobbering the rest of the row")
    func setupUpdateKeepsTheRestOfTheRow() async throws {
        let store = try makeTestStore("store")
        let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r"))
        let stale = try await store.upsert(Workspace(
            repoID: repo.id, name: "original", branch: "b", path: "/p", baseBranch: "main",
            setupState: .running
        ))

        // Stands in for everything that can write the row while a setup script runs for minutes:
        // a rename from the UI, a diff stat from the background refresh, a pin.
        try await store.upsert(stale.with {
            $0.name = "renamed while setup ran"
            $0.pinned = true
        })
        try await store.updateDiffStat(workspaceID: stale.id, additions: 12, deletions: 3, files: 2)

        try await store.update(workspaceID: stale.id) {
            $0.apply(.runStarted)
            $0.apply(.runFinished(succeeded: true, log: "done"))
        }

        let stored = try #require(try await store.workspace(id: stale.id))
        #expect(stored.setupState == .succeeded)
        #expect(stored.setupLog == "done")
        #expect(stored.name == "renamed while setup ran")
        #expect(stored.pinned)
        #expect(stored.additions == 12)
        #expect(stored.changedFiles == 2)
    }

    @Test("survives a reopen")
    func survivesReopen() async throws {
        let path = TestScratch.unique("bloom-persist") + ".sqlite"
        let first = try Store(path: path)
        try await first.upsert(Repo(name: "persisted", path: "/tmp/p"))

        let second = try Store(path: path)
        #expect(try await second.repos().map(\.name) == ["persisted"])
    }
}
