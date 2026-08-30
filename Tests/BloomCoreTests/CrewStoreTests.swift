import Foundation
import Testing
@testable import BloomCore

/// The store's half of a crew: one read for the whole sidebar, and news for an orchestrator whose
/// agent did not survive a relaunch.
///
/// Both of these are bugs written down rather than features described. The sidebar asked one query
/// per workspace on every write to a table a running agent rewrites several times a turn, and a
/// crew member caught by `resetRunningSessions` left the chat that started it waiting for a report
/// that could never arrive.
@Suite("The store's half of a crew", .tags(.persistence), .scratchDirectory)
struct CrewStoreTests {
    private func makeWorkspace(
        _ store: Store, _ label: String, repo: Repo
    ) async throws -> Workspace {
        try await store.upsert(Workspace(
            repoID: repo.id,
            name: label,
            branch: "bloom/\(label)",
            path: TestScratch.unique("worktree-\(label)"),
            baseBranch: "main"
        ))
    }

    @discardableResult
    private func makeMember(
        _ store: Store,
        _ name: String,
        in workspace: Workspace,
        of parent: Session,
        state: SessionState = .idle
    ) async throws -> Session {
        try await store.upsert(Session(
            workspaceID: workspace.id,
            parentSessionID: parent.id,
            title: name,
            state: state
        ))
    }

    // MARK: - One read for the whole window

    /// The grouped read is the sidebar's, so what it must not do is disagree with the per
    /// workspace one it replaced: same members, same worktrees, same exclusions.
    @Test("every crew member in the app comes back in one read, grouped by worktree")
    func crewGroupsByWorkspace() async throws {
        let store = try makeTestStore("crew-grouped")
        let repo = try await store.upsert(Repo(name: "bloom", path: TestScratch.unique("repo")))
        let one = try await makeWorkspace(store, "one", repo: repo)
        let two = try await makeWorkspace(store, "two", repo: repo)

        let chatOne = try await store.upsert(Session(workspaceID: one.id, title: "Chat"))
        let chatTwo = try await store.upsert(Session(workspaceID: two.id, title: "Chat"))
        // A chat nobody started, in a worktree with a crew, so the read has something to exclude
        // that is not merely absent.
        try await store.upsert(Session(workspaceID: one.id, title: "Second chat"))
        try await store.upsert(Session(workspaceID: nil, title: "Ask Bloom"))

        try await makeMember(store, "tests", in: one, of: chatOne)
        try await makeMember(store, "docs", in: one, of: chatOne)
        try await makeMember(store, "cascade", in: two, of: chatTwo)
        let archived = try await makeMember(store, "gone", in: two, of: chatTwo)
        try await store.update(sessionID: archived.id) { $0.archivedAt = Date() }

        let grouped = try await store.crewByWorkspace()

        #expect(Set(grouped.keys) == [one.id, two.id])
        #expect(grouped[one.id].map { Set($0.map(\.title)) } == ["tests", "docs"])
        #expect(grouped[two.id].map { Set($0.map(\.title)) } == ["cascade"])
        // The two reads answer the same question, so they answer it the same way.
        for workspace in [one, two] {
            let perWorkspace = try await store.crew(inWorkspace: workspace.id)
            #expect(grouped[workspace.id].map { Set($0.map(\.id)) } == Set(perWorkspace.map(\.id)))
        }
    }

    /// Nothing to draw is an empty dictionary rather than a key with an empty list, because the
    /// sidebar compares whole values and a phantom key is a redraw.
    @Test("an app with no crew reads back as nothing at all")
    func crewIsEmptyWithoutMembers() async throws {
        let store = try makeTestStore("crew-grouped-empty")
        let repo = try await store.upsert(Repo(name: "bloom", path: TestScratch.unique("repo")))
        let workspace = try await makeWorkspace(store, "solo", repo: repo)
        try await store.upsert(Session(workspaceID: workspace.id, title: "Chat"))

        #expect(try await store.crewByWorkspace().isEmpty)
    }

    // MARK: - The relaunch an orchestrator has to be told about

    /// Quit with a crew working, reopen, and the orchestrator has a dead agent and no news. This
    /// is the sentence `Crew.failedSentence` exists for.
    @Test("a crew member lost to a relaunch is reported to the chat that started it")
    func relaunchReportsLostCrew() async throws {
        let store = try makeTestStore("crew-relaunch")
        let repo = try await store.upsert(Repo(name: "bloom", path: TestScratch.unique("repo")))
        let workspace = try await makeWorkspace(store, "crew", repo: repo)
        let orchestrator = try await store.upsert(Session(workspaceID: workspace.id, title: "Chat"))

        let working = try await makeMember(
            store, "tests", in: workspace, of: orchestrator, state: .running
        )
        let blocked = try await makeMember(
            store, "docs", in: workspace, of: orchestrator, state: .waiting
        )
        // Idle when the app died, so there is nothing to report: it had already stopped and the
        // orchestrator was told at the time.
        try await makeMember(store, "quiet", in: workspace, of: orchestrator, state: .idle)

        try await store.resetRunningSessions()

        let pending = try await store.pendingDeliveries(sessionID: orchestrator.id)
        #expect(pending.count == 2)
        #expect(pending.allSatisfy { $0.kind == .report })
        #expect(pending.allSatisfy { $0.sourceWorkspaceID == workspace.id })
        #expect(pending.allSatisfy { $0.body.contains("restarted") })
        #expect(pending.contains { $0.body.contains("\"tests\"") })
        #expect(pending.contains { $0.body.contains("\"docs\"") })
        #expect(pending.allSatisfy { !$0.body.contains("\"quiet\"") })

        // The reset itself still happened, which is the half that keeps the ceiling in `Crew` from
        // staying stuck on agents that are not running.
        #expect(try await store.session(id: working.id)?.state == .idle)
        #expect(try await store.session(id: blocked.id)?.state == .idle)
    }

    /// A delivery addressed to a closed chat is a row nothing will ever drain.
    @Test("an archived orchestrator is told nothing")
    func archivedOrchestratorIsNotTold() async throws {
        let store = try makeTestStore("crew-relaunch-archived")
        let repo = try await store.upsert(Repo(name: "bloom", path: TestScratch.unique("repo")))
        let workspace = try await makeWorkspace(store, "crew", repo: repo)
        let orchestrator = try await store.upsert(Session(workspaceID: workspace.id, title: "Chat"))
        let member = try await makeMember(
            store, "tests", in: workspace, of: orchestrator, state: .running
        )
        try await store.update(sessionID: orchestrator.id) { $0.archivedAt = Date() }

        try await store.resetRunningSessions()

        #expect(try await store.pendingDeliveries(sessionID: orchestrator.id).isEmpty)
        #expect(try await store.session(id: member.id)?.state == .idle)
    }

    /// Nearly every chat in the app has no parent, and none of them may put a delivery anywhere.
    @Test("an ordinary chat left running produces no delivery")
    func ordinaryChatProducesNothing() async throws {
        let store = try makeTestStore("crew-relaunch-plain")
        let repo = try await store.upsert(Repo(name: "bloom", path: TestScratch.unique("repo")))
        let workspace = try await makeWorkspace(store, "plain", repo: repo)
        let chat = try await store.upsert(Session(
            workspaceID: workspace.id, title: "Chat", state: .running
        ))

        try await store.resetRunningSessions()

        #expect(try await store.pendingDeliveries(sessionID: chat.id).isEmpty)
        #expect(try await store.session(id: chat.id)?.state == .idle)
    }
}
