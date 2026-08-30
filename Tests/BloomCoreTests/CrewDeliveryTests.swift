import Foundation
import Testing
@testable import BloomCore

/// The storage and delivery half of a crew message: what the queue carries, what the model is
/// handed, and what the window is left to draw.
///
/// **The bug underneath all of it.** A message from one agent to another is wrapped for the model
/// in the untrusted envelope, and the row that recorded it was written with exactly the bytes that
/// went out, in the bucket that means "the owner typed this". Six lines of plumbing appeared in the
/// owner's own bubble. So a delivery carries both renderings from the moment it is made, and the
/// two of them part company in exactly one place: `Delivery.sent` goes to the agent and
/// `Delivery.body` is what a person reads.
@Suite("A crew message on its way to an agent", .tags(.persistence), .scratchDirectory)
struct CrewDeliveryTests {
    private func makeMember(_ store: Store) async throws -> (Workspace, Session) {
        let repo = try await store.upsert(Repo(name: "bloom", path: TestScratch.unique("repo")))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id,
            name: "crew",
            branch: "bloom/crew",
            path: TestScratch.unique("worktree"),
            baseBranch: "main"
        ))
        let parent = try await store.upsert(Session(workspaceID: workspace.id, title: "Chat"))
        let member = try await store.upsert(Session(
            workspaceID: workspace.id, parentSessionID: parent.id, title: "reader"
        ))
        return (workspace, member)
    }

    // MARK: - What a delivery carries

    @Test("a delivery holds the words a person reads and the envelope the model is handed")
    func carriesBothRenderings() throws {
        let message = CrewMessage.said(from: "reader", text: "All 18 tests pass.", sender: .subagent)
        let delivery = Delivery(targetSessionID: SessionID("s"), kind: .message, crew: message)

        #expect(delivery.body == "All 18 tests pass.")
        #expect(delivery.sent == message.sent)
        #expect(delivery.sent.contains(BridgeUntrustedText.opening))
        // The half that goes on screen must never be the half that went to the model.
        #expect(!delivery.body.contains(BridgeUntrustedText.opening))
        #expect(delivery.crewMessage == message)
    }

    /// The owner's own message is one string doing both jobs, and nothing about this may change
    /// that: `sent` has to answer for a plain delivery without a payload to read it out of.
    @Test("a message the owner typed carries no crew payload and is sent as it stands")
    func ownerMessagesAreUnchanged() {
        let delivery = Delivery(targetSessionID: SessionID("s"), body: "list the technologies used")

        #expect(delivery.crewPayload == nil)
        #expect(delivery.crewMessage == nil)
        #expect(delivery.sent == "list the technologies used")
    }

    /// A brief is the task the agent exists to follow, so the two halves are the same string. It
    /// still travels as a crew message, because the row it becomes says who set the task.
    @Test("a brief is carried as a crew message even though it is not wrapped")
    func briefTravelsAsCrew() throws {
        let brief = CrewMessage.brief(from: "Chat", task: "Read the cascade and report.")
        let delivery = Delivery(targetSessionID: SessionID("s"), kind: .message, crew: brief)

        #expect(delivery.body == "Read the cascade and report.")
        #expect(delivery.sent == "Read the cascade and report.")
        #expect(delivery.crewMessage?.event == .brief)
    }

    // MARK: - Through the table and back

    @Test("both renderings survive the queue")
    func survivesTheTable() async throws {
        let store = try makeTestStore("crew-delivery")
        let (workspace, member) = try await makeMember(store)
        let message = CrewMessage.stopped(name: "reader", lastMessage: "All 18 tests pass.")

        let written = try await store.enqueueDelivery(Delivery(
            targetSessionID: member.id,
            sourceWorkspaceID: workspace.id,
            kind: .report,
            crew: message
        ))

        let pending = try await store.pendingDeliveries(sessionID: member.id)
        #expect(pending.count == 1)
        let read = try #require(pending.first)
        #expect(read.id == written.id)
        #expect(read.kind == .report)
        // Byte for byte, because these are the same bytes the `messages` row is written with: the
        // queue and the transcript must not be able to disagree about what was said.
        #expect(read.crewPayload == written.crewPayload)
        #expect(read.crewMessage == message)
        #expect(read.body == message.text)
        #expect(read.sent == message.sent)
    }

    @Test("a message the owner typed reads back with the column empty")
    func ownerRowsStayEmpty() async throws {
        let store = try makeTestStore("crew-delivery-owner")
        let (_, member) = try await makeMember(store)
        try await store.enqueueDelivery(Delivery(targetSessionID: member.id, body: "carry on"))

        let read = try #require(try await store.pendingDeliveries(sessionID: member.id).first)
        #expect(read.crewPayload == nil)
        #expect(read.sent == "carry on")
    }

    /// The store's own tests rewind `user_version` to reproduce an old schema, so every step in
    /// the list has to be replayable over a database that already has it. This one is an
    /// `ADD COLUMN`, which has no `IF NOT EXISTS`, and a step that threw would take the whole
    /// migration transaction with it.
    @Test("the column's migration replays over a database that already has it")
    func migrationReplays() async throws {
        let path = TestScratch.unique("crew-delivery-migration") + ".sqlite"
        let store = try Store(path: path)
        let (workspace, member) = try await makeMember(store)
        let message = CrewMessage.said(from: "Chat", text: "Carry on.", sender: .orchestrator)
        let crew = try await store.enqueueDelivery(Delivery(
            targetSessionID: member.id,
            sourceWorkspaceID: workspace.id,
            kind: .message,
            crew: message
        ))
        let typed = try await store.enqueueDelivery(
            Delivery(targetSessionID: member.id, body: "and then stop")
        )

        let raw = try SQLiteDatabase(path: path)
        raw.userVersion = 0

        let reopened = try Store(path: path)
        let pending = try await reopened.pendingDeliveries(sessionID: member.id)
        #expect(pending.map(\.id) == [crew.id, typed.id])
        // The replay is not allowed to empty a column somebody's message is in.
        #expect(pending.first?.crewMessage == message)
        #expect(pending.last?.crewPayload == nil)
    }

    // MARK: - What the drain hands the runner

    /// The seam the whole fix turns on: one call, one row, and the caller says which of the two
    /// strings each of the two readers gets.
    @Test("the drain hands the model the envelope and the runner the row to write down")
    func drainSeparatesTheTwoHalves() async throws {
        let runner = RecordingRunner()
        let message = CrewMessage.said(from: "reader", text: "Done.", sender: .subagent)
        let delivery = Delivery(targetSessionID: SessionID("s"), kind: .message, crew: message)

        try await runner.send(delivery.sent, recording: delivery.crewPayload)

        let turn = try #require(await runner.turns.first)
        #expect(turn.text == message.sent)
        #expect(CrewMessage.decode(try #require(turn.recording)) == message)
    }

    /// Every caller that had nothing to record predates the second argument, and all of them still
    /// compile and still mean the same thing.
    @Test("a turn with nothing to record still goes out under one argument")
    func oneArgumentStillWorks() async throws {
        let runner = RecordingRunner()

        try await runner.send("list the technologies used")

        let turn = try #require(await runner.turns.first)
        #expect(turn.text == "list the technologies used")
        #expect(turn.recording == nil)
    }
}

/// A runner that writes nothing and remembers everything, for the two tests above. It is the seam
/// rather than a backend: what is being pinned is that a caller can say "send this, record that".
private actor RecordingRunner: SessionRunner {
    struct Turn: Sendable {
        var text: String
        var recording: Data?
    }

    private(set) var turns: [Turn] = []

    nonisolated var agentKind: AgentKind { .claudeCode }
    nonisolated var events: AsyncStream<AgentEvent> { AsyncStream { $0.finish() } }
    var isProcessAlive: Bool { false }

    func send(_ text: String, recording: Data?) async throws {
        turns.append(Turn(text: text, recording: recording))
    }

    nonisolated func cancelNow() {}
    nonisolated func terminateNow() {}
    func answer(requestID: String, decision: PermissionDecision) async {}
}

/// What agent_stop leaves behind.
///
/// **Stopping a subagent is three things and losing the conversation is not one of them.** The
/// agent ends, its row leaves the sidebar and its name comes free, which is what an orchestrator
/// saying "I am finished with this one" means. The account of what the agent did is often the only
/// record of an hour of work, and the owner reads it after the fact, so the row is archived and
/// never deleted.
///
/// `WorkspaceModel.stopCrewMember` is in the app target and nothing here can see it. What these
/// tests pin is the store contract it stands on: archiving takes a member out of every crew read
/// while leaving the row and its transcript exactly where they are.
@Suite("What stopping a subagent leaves behind", .tags(.persistence), .scratchDirectory)
struct CrewStopTests {
    private func makeCrew(_ store: Store) async throws -> (Workspace, Session, Session) {
        let repo = try await store.upsert(Repo(name: "bloom", path: TestScratch.unique("repo")))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id,
            name: "crew",
            branch: "bloom/crew",
            path: TestScratch.unique("worktree"),
            baseBranch: "main"
        ))
        let parent = try await store.upsert(Session(workspaceID: workspace.id, title: "Chat"))
        let member = try await store.upsert(Session(
            workspaceID: workspace.id, parentSessionID: parent.id, title: "reader"
        ))
        return (workspace, parent, member)
    }

    @Test("the conversation is still there to read after the agent is stopped")
    func archivesRatherThanDeletes() async throws {
        let store = try makeTestStore("crew-stop")
        let (_, _, member) = try await makeCrew(store)
        let brief = CrewMessage.brief(from: "Chat", task: "Read the cascade.")
        try await store.appendNext(sessionID: member.id, kind: .crew, payload: brief.payload())
        try await store.appendNext(
            sessionID: member.id, kind: .assistantText, payload: Data("{}".utf8)
        )

        // One column, which is what `closeSession` writes and all that stopping changes.
        _ = try await store.update(sessionID: member.id) { $0.archivedAt = Date() }

        let stopped = try #require(try await store.session(id: member.id))
        #expect(stopped.archivedAt != nil)
        #expect(stopped.title == "reader")
        let rows = try await store.messages(sessionID: member.id)
        #expect(rows.count == 2)
        #expect(rows.first?.kind == .crew)
        #expect(CrewMessage.decode(try #require(rows.first?.payload)) == brief)
    }

    @Test("the row leaves the sidebar and the name comes free")
    func freesTheNameAndTheRow() async throws {
        let store = try makeTestStore("crew-stop-name")
        let (workspace, parent, member) = try await makeCrew(store)

        _ = try await store.update(sessionID: member.id) { $0.archivedAt = Date() }

        #expect(try await store.crew(of: parent.id).isEmpty)
        #expect(try await store.crew(inWorkspace: workspace.id).isEmpty)
        #expect(try await store.crewByWorkspace()[workspace.id] == nil)

        // Which is what a second agent under the same name is weighed against, so the name the
        // orchestrator has finished with is one it may use again rather than one it has to
        // invent "-2" for.
        let existing = Set(try await store.crew(of: parent.id).map(\.title))
        let started = Crew.start(
            name: "reader", existing: existing, running: 0, callerIsSubagent: false
        )
        #expect(started == .success("reader"))
    }
}
