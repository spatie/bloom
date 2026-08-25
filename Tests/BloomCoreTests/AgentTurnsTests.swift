import Foundation
import Testing
@testable import BloomCore

/// Whether an agent is working in a workspace, which the sidebar's mark is the whole of.
///
/// Written from a screenshot. Three workspaces under one project: a green tick, a running dot, and
/// a workspace drawing `circle.dotted`, the mark for a worktree with nothing in it, while the
/// centre column beside it streamed a turn. The session row said `running` for the whole of it,
/// and the mark was fed `isRunning: false`, so `WorkspaceStatus.resolve` fell through every test
/// and landed on `.clean`. The mark was right about what it was told; what it was told was wrong.
///
/// So these are about the two sources disagreeing, which is the only interesting thing here: a
/// live transcript that this launch has built, and the row the runner writes whether or not
/// anybody is watching.
@Suite("Agent turns")
struct AgentTurnsTests {
    private let workspace = WorkspaceID("w1")
    private let other = WorkspaceID("w2")

    private func stored(
        _ session: String,
        _ state: SessionState,
        in workspaceID: WorkspaceID? = nil
    ) -> SessionActivity {
        SessionActivity(
            sessionID: SessionID(session),
            workspaceID: workspaceID ?? workspace,
            state: state
        )
    }

    private func live(
        _ session: String,
        running: Bool = false,
        waiting: Bool = false,
        in workspaceID: WorkspaceID? = nil
    ) -> AgentTurns.Live {
        AgentTurns.Live(
            sessionID: SessionID(session),
            workspaceID: workspaceID ?? workspace,
            isRunning: running,
            isAwaitingPermission: waiting
        )
    }

    // MARK: - The bug

    /// The screenshot, reduced. Nothing has built a transcript for this chat, so the old walk of
    /// the live transcripts answered no while the row said the agent was mid turn.
    @Test("a running chat with no live transcript still reports its workspace")
    func storedRowAloneCounts() {
        let running = AgentTurns.workspaces(
            .running, stored: [stored("s1", .running)], live: []
        )
        #expect(running == [workspace])
    }

    /// The other half of the same bug: the turn has started and the runner has not written the row
    /// yet. The mark has to be on from the frame the turn started, not from the frame the store
    /// heard about it.
    @Test("a live turn counts before its row has been written")
    func liveTurnAloneCounts() {
        let running = AgentTurns.workspaces(
            .running, stored: [], live: [live("s1", running: true)]
        )
        #expect(running == [workspace])
    }

    // MARK: - Precedence

    /// The reason this is not a union. The row lags the transcript by exactly the write that ends
    /// the turn, so a workspace whose agent has just finished would keep its mark until the runner
    /// got round to saying so.
    @Test("a live transcript overrules its own stale row")
    func liveOverrulesStaleRow() {
        let running = AgentTurns.workspaces(
            .running, stored: [stored("s1", .running)], live: [live("s1", running: false)]
        )
        #expect(running.isEmpty)
    }

    /// And the other direction, which is the one that matters for the mark going ON: the row says
    /// idle because nothing has been written yet, and the transcript knows better.
    @Test("a live transcript overrules an idle row")
    func liveOverrulesIdleRow() {
        let running = AgentTurns.workspaces(
            .running, stored: [stored("s1", .idle)], live: [live("s1", running: true)]
        )
        #expect(running == [workspace])
    }

    /// One session having a transcript says nothing about the others. This is the workspace with
    /// four chats: the one on screen has finished and one nobody has opened is still going.
    @Test("a live answer settles its own session and no other")
    func liveAnswerDoesNotSettleSiblings() {
        let running = AgentTurns.workspaces(
            .running,
            stored: [stored("s1", .running), stored("s2", .running)],
            live: [live("s1", running: false)]
        )
        #expect(running == [workspace])
    }

    @Test("a workspace with nothing going on is not reported")
    func quietWorkspace() {
        let running = AgentTurns.workspaces(
            .running,
            stored: [stored("s1", .idle), stored("s2", .waiting)],
            live: [live("s3", running: false)]
        )
        #expect(running.isEmpty)
    }

    // MARK: - The two questions

    /// A blocked agent is not a working one, and the sidebar draws them differently on purpose:
    /// `awaitingPermission` outranks `running` precisely because it is the state where time is
    /// wasted. The two sets must not bleed into each other.
    @Test("waiting and running are separate answers")
    func waitingIsNotRunning() {
        let stored = [stored("s1", .waiting)]
        #expect(AgentTurns.workspaces(.running, stored: stored, live: []).isEmpty)
        #expect(AgentTurns.workspaces(.awaitingPermission, stored: stored, live: []) == [workspace])
    }

    @Test("a live transcript answers both questions for its session")
    func liveAnswersBoth() {
        let live = [live("s1", running: false, waiting: true)]
        #expect(AgentTurns.workspaces(.running, stored: [stored("s1", .running)], live: live).isEmpty)
        #expect(
            AgentTurns.workspaces(.awaitingPermission, stored: [stored("s1", .running)], live: live)
                == [workspace]
        )
    }

    // MARK: - Several workspaces

    @Test("each workspace is answered from its own sessions")
    func workspacesAreSeparate() {
        let running = AgentTurns.workspaces(
            .running,
            stored: [stored("s1", .running), stored("s2", .idle, in: other)],
            live: [live("s2", running: false, in: other)]
        )
        #expect(running == [workspace])
    }

    @Test("two workspaces working at once are both reported")
    func bothReported() {
        let running = AgentTurns.workspaces(
            .running,
            stored: [stored("s1", .running)],
            live: [live("s2", running: true, in: other)]
        )
        #expect(running == [workspace, other])
    }

    // MARK: - One workspace, from what its own model holds

    /// The same rule asked the way `WorkspaceModel` asks it, over the session rows and transcripts
    /// one workspace holds. Any chat counts: a workspace with four of them runs four turns, and
    /// one finishing does not mean the workspace has stopped working.
    @Test("a workspace is working while any of its chats is")
    func workspaceCountsAnySession() {
        let sessions = [
            Session(id: SessionID("s1"), workspaceID: workspace),
            Session(id: SessionID("s2"), workspaceID: workspace),
        ]
        var running = sessions[1]
        running.apply(.turnStarted)

        #expect(!AgentTurns.workspace(.running, sessions: sessions, live: []))
        #expect(AgentTurns.workspace(.running, sessions: [sessions[0], running], live: []))
        #expect(
            AgentTurns.workspace(.running, sessions: sessions, live: [live("s1", running: true)])
        )
    }

    /// A workspace whose rows have not been read yet answers no rather than crashing into a
    /// default of yes. The empty case is the one every reader hits at launch.
    @Test("a workspace with no sessions read yet is not working")
    func workspaceWithNothingRead() {
        #expect(!AgentTurns.workspace(.running, sessions: [], live: []))
        #expect(!AgentTurns.workspace(.awaitingPermission, sessions: [], live: []))
    }

    // MARK: - The states the two questions read

    /// The SQL that reads the rows is built out of this table, so a third turn kind added here
    /// would be read out of the store without anybody remembering to widen a `WHERE` clause. See
    /// `Store.sessionActivity`.
    @Test("every turn kind names the stored state it means")
    func turnStates() {
        #expect(AgentTurns.Kind.running.sessionState == .running)
        #expect(AgentTurns.Kind.awaitingPermission.sessionState == .waiting)
        #expect(AgentTurns.Kind.allCases.count == 2)
    }
}

/// The durable half, read back out of a real database.
@Suite("Session activity rows", .tags(.persistence), .scratchDirectory)
struct SessionActivityRowTests {
    private func seed(_ store: Store, name: String) async throws -> Workspace {
        let repo = try await store.upsert(Repo(name: name, path: TestScratch.unique("repo-" + name)))
        return try await store.upsert(Workspace(
            repoID: repo.id, name: name, branch: "feature/" + name,
            path: TestScratch.unique("worktree-" + name), baseBranch: "main"
        ))
    }

    @Test("only chats that are mid turn or blocked come back")
    func onlyBusyChats() async throws {
        let store = try makeTestStore("activity")
        let workspace = try await seed(store, name: "alpha")

        var running = Session(workspaceID: workspace.id)
        running.apply(.turnStarted)
        var waiting = Session(workspaceID: workspace.id)
        waiting.apply(.turnStarted)
        waiting.apply(.blocked)
        let idle = Session(workspaceID: workspace.id)

        for session in [running, waiting, idle] { _ = try await store.upsert(session) }

        let rows = try await store.sessionActivity()
        #expect(Set(rows.map(\.sessionID)) == [running.id, waiting.id])
        #expect(rows.allSatisfy { $0.workspaceID == workspace.id })
        #expect(rows.first { $0.sessionID == waiting.id }?.state == .waiting)
    }

    /// A closed chat has no agent in it, and neither has an archived workspace. Reporting either
    /// would put a running mark on a row the sidebar does not draw, and a name in the confirmation
    /// shown on quit.
    @Test("a closed chat and an archived workspace are left out")
    func closedAndArchivedAreLeftOut() async throws {
        let store = try makeTestStore("activity-archived")

        let live = try await seed(store, name: "live")
        var closed = Session(workspaceID: live.id)
        closed.apply(.turnStarted)
        closed = try await store.upsert(closed)
        _ = try await store.update(sessionID: closed.id) { $0.archivedAt = Date() }

        var gone = try await seed(store, name: "gone")
        var stillRunning = Session(workspaceID: gone.id)
        stillRunning.apply(.turnStarted)
        _ = try await store.upsert(stillRunning)
        gone.archive()
        _ = try await store.upsert(gone)

        #expect(try await store.sessionActivity().isEmpty)
    }
}
