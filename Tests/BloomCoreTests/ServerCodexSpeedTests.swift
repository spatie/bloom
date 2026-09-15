import Foundation
import Testing
@testable import BloomCore

/// A remote conversation's Codex speed has two halves: the override a client chose, which the
/// server must keep through every later settings change, and the server's own reading, which it
/// reports only when that reading describes the Codex that will run the turn.
struct ServerCodexSpeedTests {
    @Test func changingOnlyTheModelKeepsTheStoredFastModeOverride() async throws {
        let repo = try await TempRepo()
        let store = try makeTestStore("codex-speed-survives")
        let storedRepo = try await store.upsert(Repo(name: "Test", path: repo.path))
        let workspace = try await store.upsert(Workspace(repoID: storedRepo.id, name: "Test", branch: "main", path: repo.path, baseBranch: "main"))
        let session = try await store.upsert(Session(workspaceID: workspace.id, title: "Chat", model: "gpt-one", effort: "high", agentKind: .codex))
        try await store.setSetting(CodexSpeed.key(sessionID: session.id), "1")
        let runtime = ServerRuntime(store: store, authentication: { agent, _, _ in .init(agent: agent, state: .unknown) },
            installedAgents: { _ in [.codex] })

        // What a client sends after reading the controls back and moving only the model picker.
        var controls = try await ServerComposer.controls(session: session, store: store)
        #expect(controls.codexFastMode == true)
        controls.model = "gpt-two"
        guard case .accepted = await runtime.respond(to: ServerRequest(.setComposer(sessionID: session.id, controls: controls))).result else {
            Issue.record("Settings were refused"); await runtime.shutdown(); return
        }
        #expect(try await store.setting(CodexSpeed.key(sessionID: session.id)) == "1")

        // `configure` builds its controls on the server, with no client to carry the value back.
        let configure = ServerRequest(.configure(sessionID: session.id, model: "gpt-three", effort: "low", permissionMode: .acceptEdits))
        guard case .accepted = await runtime.respond(to: configure).result else {
            Issue.record("Configure was refused"); await runtime.shutdown(); return
        }
        #expect(try await store.setting(CodexSpeed.key(sessionID: session.id)) == "1")
        let saved = try #require(try await store.session(id: session.id))
        let reread = try await ServerComposer.controls(session: saved, store: store)
        #expect(reread.model == "gpt-three")
        #expect(reread.codexFastMode == true)
        await runtime.shutdown()
    }

    @Test func explicitStandardSpeedIsReadBackAsFalseNotInherited() async throws {
        let store = try makeTestStore("codex-speed-standard")
        let session = try await store.upsert(Session(workspaceID: nil, agentKind: .codex))
        try await store.setSetting(CodexSpeed.key(sessionID: session.id), "0")
        #expect(try await ServerComposer.controls(session: session, store: store).codexFastMode == false)
        try await store.setSetting(CodexSpeed.key(sessionID: session.id), nil)
        #expect(try await ServerComposer.controls(session: session, store: store).codexFastMode == nil)
    }

    @Test func speedsAreReportedOnlyForAnUnwrappedServerCodex() async {
        let speeds = ["gpt-one": CodexSpeed(isFast: true, supportsFast: true)]
        let reported = await ServerComposer.codexSpeeds(cwd: "/server/work", available: [.codex], wrapped: false) { cwd in
            #expect(cwd == "/server/work")
            return speeds
        }
        #expect(reported == speeds)
        let notInstalled = await ServerComposer.codexSpeeds(cwd: "/server/work", available: [.claudeCode], wrapped: false) { _ in speeds }
        #expect(notInstalled == nil)
        let wrapped = await ServerComposer.codexSpeeds(cwd: "/server/work", available: [.codex], wrapped: true) { _ in speeds }
        #expect(wrapped == nil)
        let unreadable = await ServerComposer.codexSpeeds(cwd: "/server/work", available: [.codex], wrapped: false) { _ in
            throw ServerFailure("Codex did not start.")
        }
        #expect(unreadable == nil)
    }
}
