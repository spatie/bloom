import Foundation
import Testing
@testable import BloomCore

/// The check the tool makes while the asking turn is still running, and the one the app makes
/// again once it has ended. Both go through here, so this is where the difference between them is
/// written down: one excuses the chat that is asking, the other excuses nothing.
struct WorkspaceArchiveSafetyTests {
    @Test("a quiet workspace has nothing to object to")
    func quiet() async throws {
        let (store, workspace) = try await fixture()
        try await store.upsert(Session(workspaceID: workspace.id, title: "Finished"))
        #expect(await WorkspaceArchiveSafety.objection(to: workspace, excusing: nil, store: store) == nil)
    }

    @Test("the asking chat's own turn is the call in flight rather than work at risk")
    func asksAreExcused() async throws {
        let (store, workspace) = try await fixture()
        var asking = Session(workspaceID: workspace.id, title: "Asking")
        asking.state = .running
        asking = try await store.upsert(asking)

        // While it asks: nothing objects, because the only thing running is the turn making the
        // call.
        #expect(await WorkspaceArchiveSafety.objection(
            to: workspace, excusing: asking.id, store: store
        ) == nil)

        // The recheck, made with nothing excused. A chat still marked running when the archive is
        // due is a turn that never ended, and the worktree stays.
        let objection = await WorkspaceArchiveSafety.objection(
            to: workspace, excusing: nil, store: store
        )
        #expect(objection?.contains("An agent is running") == true)
    }

    @Test("another chat running or waiting objects even to the chat that is asking",
          arguments: [SessionState.running, .waiting])
    func anotherAgent(_ state: SessionState) async throws {
        let (store, workspace) = try await fixture()
        let asking = try await store.upsert(Session(workspaceID: workspace.id, title: "Asking"))
        var other = Session(workspaceID: workspace.id, title: "Crew member")
        other.state = state
        try await store.upsert(other)
        let objection = await WorkspaceArchiveSafety.objection(
            to: workspace, excusing: asking.id, store: store
        )
        #expect(objection?.contains("An agent is running") == true)
    }

    @Test("a queued message is never excused, not even the asking chat's own")
    func queuedMessages() async throws {
        let (store, workspace) = try await fixture()
        var asking = Session(workspaceID: workspace.id, title: "Asking")
        asking.state = .running
        asking = try await store.upsert(asking)
        try await store.enqueueDelivery(Delivery(targetSessionID: asking.id, body: "One more thing"))
        let objection = await WorkspaceArchiveSafety.objection(
            to: workspace, excusing: asking.id, store: store
        )
        #expect(objection?.contains("queued messages") == true)
    }

    @Test("setup still running objects whoever is asking")
    func setupRunning() async throws {
        let (store, workspace) = try await fixture()
        var preparing = workspace
        preparing.setupState = .running
        preparing = try await store.upsert(preparing)
        let asking = try await store.upsert(Session(workspaceID: preparing.id, title: "Asking"))
        let objection = await WorkspaceArchiveSafety.objection(
            to: preparing, excusing: asking.id, store: store
        )
        #expect(objection?.contains("setup is still running") == true)
    }

    @Test("a chat busy in another workspace is not this workspace's problem")
    func otherWorkspacesAreIgnored() async throws {
        let (store, workspace) = try await fixture()
        let elsewhere = try await store.upsert(Workspace(
            repoID: workspace.repoID, name: "Elsewhere", branch: "elsewhere",
            path: "/tmp/archive-safety-elsewhere", baseBranch: "main"
        ))
        var busy = Session(workspaceID: elsewhere.id, title: "Busy elsewhere")
        busy.state = .running
        try await store.upsert(busy)
        #expect(await WorkspaceArchiveSafety.objection(to: workspace, excusing: nil, store: store) == nil)
    }

    private func fixture() async throws -> (Store, Workspace) {
        let store = try makeTestStore("archive-safety")
        let repo = try await store.upsert(Repo(name: "Archive safety", path: "/tmp/archive-safety"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "Finished review", branch: "review",
            path: "/tmp/archive-safety-review", baseBranch: "main"
        ))
        return (store, workspace)
    }
}
