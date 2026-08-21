import Testing
import Foundation
@testable import BloomCore

private func sessionFixtureLines() throws -> [String] {
    try bloomFixtureLines("session-basic.jsonl")
}

private func makeStoredSession(_ store: Store) async throws -> Session {
    let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r-\(UUID().uuidString)"))
    let workspace = try await store.upsert(Workspace(
        repoID: repo.id, name: "w", branch: "b", path: "/tmp/w", baseBranch: "main"
    ))
    return try await store.upsert(Session(
        workspaceID: workspace.id, title: "New session", model: "opus"
    ))
}

/// Who owns which column of a session row, and what happens when one owner writes the other's.
///
/// This row has two writers and they run at completely different speeds. `AgentRunner` owns
/// `agent_session_id`, `state`, the token counters and `updated_at`; it takes one `Session` value
/// when the workspace is opened and mutates that same value turn after turn for as long as the
/// workspace stays open. The UI owns the title, the composer's pickers, the sort order, the read
/// mark and `archived_at`, and it writes them while turns are running.
///
/// Whichever of them wrote a whole value put the other's columns back to what they were when its
/// own copy was read. The worst of it is one column: `agent_session_id` is what `--resume` is
/// built from, so a session renamed while its agent was working could no longer be continued.
@Suite("Session write isolation", .tags(.persistence), .scratchDirectory)
struct SessionWriteIsolationTests {
    // MARK: - Through the runner, which is where the value is oldest

    /// The case that costs a conversation. The composer renames the session and changes the model
    /// mid turn, and the runner then writes the next thing it learns from the agent.
    @Test("a title and a model changed mid turn survive the runner's next write")
    func runnerKeepsPreferencesChangedMidTurn() async throws {
        let store = try makeTestStore("session-isolation")
        let session = try await makeStoredSession(store)
        let runner = AgentRunner(workspacePath: "/tmp/w", session: session, store: store)

        let initLine = try #require(try sessionFixtureLines().first { $0.contains("\"subtype\":\"init\"") })
        await runner.ingest(try #require(AgentEvent.decode(line: initLine)))

        // The user renames the tab and picks a different model while the agent works.
        try await store.updateSessionPreferences(
            id: session.id, title: "Renamed mid turn", model: "sonnet", effort: "low"
        )

        // The turn finishes and the runner writes what it owns.
        let resultLine = try #require(try sessionFixtureLines().last { $0.contains("\"type\":\"result\"") })
        await runner.ingest(try #require(AgentEvent.decode(line: resultLine)))

        let stored = try #require(try await store.session(id: session.id))
        #expect(stored.title == "Renamed mid turn")
        #expect(stored.model == "sonnet")
        #expect(stored.effort == "low")
        // And the runner's own columns are still the runner's.
        #expect(stored.agentSessionID == "f93932c9-cf0b-40d8-881c-ac75db3f8740")
        #expect(stored.state == .idle)
        #expect(stored.outputTokens == 360)
    }

    /// Closing a tab while its agent is finishing is an ordinary thing to do. The runner's last
    /// write must not reopen it.
    @Test("a session closed mid turn stays closed")
    func runnerDoesNotReopenAClosedSession() async throws {
        let store = try makeTestStore("session-isolation")
        let session = try await makeStoredSession(store)
        let runner = AgentRunner(workspacePath: "/tmp/w", session: session, store: store)

        let initLine = try #require(try sessionFixtureLines().first { $0.contains("\"subtype\":\"init\"") })
        await runner.ingest(try #require(AgentEvent.decode(line: initLine)))

        try await store.update(sessionID: session.id) { $0.archivedAt = Date() }

        let resultLine = try #require(try sessionFixtureLines().last { $0.contains("\"type\":\"result\"") })
        await runner.ingest(try #require(AgentEvent.decode(line: resultLine)))

        #expect(try await store.session(id: session.id)?.archivedAt != nil)
    }

    /// Reading the transcript while the agent works writes the read mark. The runner writing the
    /// row a moment later used to make the unread badge come back.
    @Test("the read mark set while a turn ran is not undone by the runner")
    func runnerKeepsTheReadMark() async throws {
        let store = try makeTestStore("session-isolation")
        let session = try await makeStoredSession(store)
        let runner = AgentRunner(workspacePath: "/tmp/w", session: session, store: store)

        let initLine = try #require(try sessionFixtureLines().first { $0.contains("\"subtype\":\"init\"") })
        await runner.ingest(try #require(AgentEvent.decode(line: initLine)))

        try await store.updateLastReadSeq(sessionID: session.id, seq: 42)
        try await store.reorderSessions(ids: [session.id])

        let resultLine = try #require(try sessionFixtureLines().last { $0.contains("\"type\":\"result\"") })
        await runner.ingest(try #require(AgentEvent.decode(line: resultLine)))

        let stored = try #require(try await store.session(id: session.id))
        #expect(stored.lastReadSeq == 42)
        #expect(stored.sortOrder == 0)
    }

    /// The runner has to keep writing what it does own, or none of the rest of this matters.
    @Test("the runner still writes the agent session id, the state and the counters")
    func runnerStillWritesWhatItOwns() async throws {
        let store = try makeTestStore("session-isolation")
        let session = try await makeStoredSession(store)
        let runner = AgentRunner(workspacePath: "/tmp/w", session: session, store: store)

        for line in try sessionFixtureLines() {
            guard let event = AgentEvent.decode(line: line) else { continue }
            await runner.ingest(event)
        }

        let stored = try #require(try await store.session(id: session.id))
        #expect(stored.agentSessionID == "f93932c9-cf0b-40d8-881c-ac75db3f8740")
        #expect(stored.state == .idle)
        #expect(stored.inputTokens == 6)
        #expect(stored.outputTokens == 360)
        #expect(stored.costUSD > 0)
        // And resume is built from what was stored.
        #expect(await runner.launch().arguments.suffix(2)
            == ["--resume", "f93932c9-cf0b-40d8-881c-ac75db3f8740"])
    }

    /// A turn still writing after its workspace was archived must not put the row back. The
    /// cascade already took it.
    @Test("the runner cannot reinsert a session whose workspace is gone")
    func runnerDoesNotReinsertADeletedSession() async throws {
        let store = try makeTestStore("session-isolation")
        let session = try await makeStoredSession(store)
        let runner = AgentRunner(workspacePath: "/tmp/w", session: session, store: store)

        try await store.deleteSession(id: session.id)

        let resultLine = try #require(try sessionFixtureLines().last { $0.contains("\"type\":\"result\"") })
        await runner.ingest(try #require(AgentEvent.decode(line: resultLine)))

        #expect(try await store.session(id: session.id) == nil)
    }

    // MARK: - The contract

    @Test("a write leaves alone every column it did not name")
    func writeTouchesOnlyWhatItNames() async throws {
        let store = try makeTestStore("session-isolation")
        let session = try await makeStoredSession(store)

        try await store.update(sessionID: session.id) {
            $0.agentSessionID = "resume-me"
            $0.state = .running
            $0.inputTokens = 11
        }
        try await store.update(sessionID: session.id) { $0.title = "Renamed" }
        try await store.update(sessionID: session.id) { $0.archivedAt = Date() }

        let stored = try #require(try await store.session(id: session.id))
        #expect(stored.title == "Renamed")
        #expect(stored.archivedAt != nil)
        #expect(stored.agentSessionID == "resume-me")
        #expect(stored.state == .running)
        #expect(stored.inputTokens == 11)
        #expect(stored.workspaceID == session.workspaceID)
    }

    @Test("a targeted write does not recreate a session that is gone")
    func doesNotRecreateADeletedSession() async throws {
        let store = try makeTestStore("session-isolation")
        let session = try await makeStoredSession(store)
        try await store.deleteSession(id: session.id)

        let result = try await store.update(sessionID: session.id) { $0.title = "back from the dead" }

        #expect(result == nil)
        #expect(try await store.session(id: session.id) == nil)
    }

    @Test("a write cannot change which session it is or which workspace it belongs to")
    func cannotChangeIdentity() async throws {
        let store = try makeTestStore("session-isolation")
        let session = try await makeStoredSession(store)

        try await store.update(sessionID: session.id) {
            $0.id = "some-other-id"
            $0.workspaceID = WorkspaceID("some-other-workspace")
            $0.title = "Renamed"
        }

        let stored = try #require(try await store.session(id: session.id))
        #expect(stored.id == session.id)
        #expect(stored.workspaceID == session.workspaceID)
        #expect(stored.title == "Renamed")
    }

    /// Why `upsert` is for creating a session and nothing else, written down as a test: this is
    /// the write that used to cost somebody a conversation.
    @Test("a whole-value write from a copy read earlier takes the resume id with it")
    func wholeValueWriteLosesTheResumeID() async throws {
        let store = try makeTestStore("session-isolation")
        let session = try await makeStoredSession(store)
        // What the tab strip holds, read before the agent answered.
        let held = session

        try await store.update(sessionID: session.id) {
            $0.agentSessionID = "f93932c9-cf0b-40d8-881c-ac75db3f8740"
            $0.state = .running
        }
        try await store.upsert(held.with { $0.title = "Renamed" })

        let stored = try #require(try await store.session(id: session.id))
        #expect(stored.title == "Renamed")
        #expect(stored.agentSessionID == nil)
        #expect(stored.state == .idle)

        // What that costs, rather than which column changed. The live runner keeps its own copy
        // and carries on, so nothing looks wrong until the next launch builds a runner from the
        // row: no id, no `--resume`, and the conversation starts again from nothing.
        let next = AgentRunner(workspacePath: "/tmp/w", session: stored, store: store)
        #expect(await next.launch().arguments.contains("--resume") == false)
    }
}
