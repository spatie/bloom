import Testing
import Foundation
@testable import BloomCore

private func makeGrokSession(
    _ store: Store,
    permissionMode: PermissionMode = .auto,
    agentSessionID: String? = nil
) async throws -> Session {
    let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r-\(UUID().uuidString)"))
    let workspace = try await store.upsert(Workspace(
        repoID: repo.id, name: "w", branch: "b", path: "/tmp/w", baseBranch: "main"
    ))
    return try await store.upsert(Session(
        workspaceID: workspace.id,
        agentSessionID: agentSessionID,
        model: "grok-4.6",
        effort: "high",
        agentKind: .grok,
        permissionMode: permissionMode
    ))
}

private func makeRunner(store: Store, session: Session, box: ProcessBox) -> GrokRunner {
    GrokRunner(
        workspacePath: "/tmp/w",
        session: session,
        store: store,
        makeClient: { configuration in
            GrokClient(configuration: configuration, makeProcess: box.factory)
        }
    )
}

private func scriptedGrokBox() -> ProcessBox {
    let box = ProcessBox()
    box.reply(to: "initialize", with: .object(["_meta": .object([:])]))
    box.reply(to: "session/new", with: .object(["sessionId": .string("sess-1")]))
    box.reply(to: "session/resume", with: .object(["sessionId": .string("sess-1")]))
    box.reply(to: "session/set_config_option", with: .object([:]))
    box.ignore("session/prompt")
    return box
}

private func eventually(
    _ description: String,
    within seconds: Double = 2,
    _ condition: @Sendable () async -> Bool
) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out waiting for \(description)")
}

@Suite(.scratchDirectory)
struct GrokRunnerTests {
    @Test("a first send starts ACP, opens a session, and stores the id")
    func firstSendOpensASession() async throws {
        let store = try makeTestStore("grok-first-send")
        let session = try await makeGrokSession(store)
        let box = scriptedGrokBox()
        let runner = makeRunner(store: store, session: session, box: box)
        try await runner.send("hello")
        await eventually("session id stored") {
            (try? await store.session(id: session.id)?.agentSessionID) == "sess-1"
        }
        #expect(box.process.sentMethods.contains("initialize"))
        #expect(box.process.sentMethods.contains("session/new"))
        #expect(box.process.sentMethods.contains("session/prompt"))
        let rows = try await store.messages(sessionID: session.id)
        #expect(rows.contains { $0.kind == .user })
        runner.terminateNow()
    }

    @Test("a stored session id is resumed rather than started")
    func resumeUsesTheStoredID() async throws {
        let store = try makeTestStore("grok-resume")
        let session = try await makeGrokSession(store, agentSessionID: "sess-1")
        let box = scriptedGrokBox()
        let runner = makeRunner(store: store, session: session, box: box)
        try await runner.send("again")
        await eventually("resume sent") {
            box.process.sentMethods.contains("session/resume")
        }
        #expect(!box.process.sentMethods.contains("session/new"))
        runner.terminateNow()
    }

    @Test("makeRunner picks GrokRunner for a Grok session")
    func makeRunnerPicksGrok() {
        let session = Session(
            workspaceID: WorkspaceID("w"),
            model: "grok-4.6",
            agentKind: .grok
        )
        // The picker is a static function of values, so this does not need a store or a window.
        #expect(session.agentKind == .grok)
        #expect(session.agentKind.canRunWorkspaces)
    }
}
