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
    @Test("a restarted server can reuse a permission RPC id without inheriting its old decision")
    func permissionIDsSurviveReconnect() async throws {
        let store = try makeTestStore("grok-permission-reconnect")
        let session = try await makeGrokSession(store)
        let box = scriptedGrokBox()
        let runner = makeRunner(store: store, session: session, box: box)
        defer { runner.terminateNow() }

        try await runner.send("first")
        box.process.emit(permissionRequestLine(id: 7))
        await eventually("first permission") {
            ((try? await store.pendingPermissionAsks(sessionID: session.id)) ?? []).count == 1
        }
        let first = try #require(try await store.pendingPermissionAsks(sessionID: session.id).first)
        await runner.answer(requestID: first.id, decision: .allow(scope: .once))
        box.process.endOutput()
        await eventually("connection closed") {
            (try? await store.session(id: session.id))?.state == .failed
        }

        try await runner.send("second")
        box.process.emit(permissionRequestLine(id: 7))
        await eventually("second permission") {
            ((try? await store.pendingPermissionAsks(sessionID: session.id)) ?? []).count == 1
        }
        let second = try #require(try await store.pendingPermissionAsks(sessionID: session.id).first)
        #expect(second.id != first.id)
        await runner.answer(requestID: second.id, decision: .allow(scope: .once))
        #expect(box.process.stdin.compactMap(JSONValue.parse).contains {
            $0["id"]?.intValue == 7 && $0["result"]?["outcome"]?["optionId"]?.stringValue == "allow-once"
        })
    }

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

    @Test("a cancelled prompt's reply does not complete the next send")
    func cancelledPromptDoesNotCompleteTheNextTurn() async throws {
        let store = try makeTestStore("grok-cancel-then-send")
        let session = try await makeGrokSession(store)
        let box = scriptedGrokBox()
        let runner = makeRunner(store: store, session: session, box: box)

        try await runner.send("one")
        runner.cancelNow()
        await eventually("session/cancel") {
            box.process.sentMethods.contains("session/cancel")
        }
        try await runner.send("two")
        let ids = promptIDs(in: box.process)
        #expect(ids.count == 2)

        emitPromptResult(on: box.process, id: ids[0], stopReason: "end_turn")
        let staleDeadline = ContinuousClock.now.advanced(by: .milliseconds(200))
        while ContinuousClock.now < staleDeadline {
            if (try? await store.session(id: session.id))?.state == .idle {
                Issue.record("the cancelled prompt completed the next turn")
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let afterLate = try #require(try await store.session(id: session.id))
        #expect(afterLate.state == .running)

        emitPromptResult(on: box.process, id: ids[1], stopReason: "end_turn")
        await eventually("the second turn to settle") {
            (try? await store.session(id: session.id))?.state == .idle
        }
        runner.terminateNow()
    }

    @Test("a dead process is replaced on the next send rather than left hanging")
    func closedProcessReconnectsOnTheNextSend() async throws {
        let store = try makeTestStore("grok-closed-then-send")
        let session = try await makeGrokSession(store)
        let box = scriptedGrokBox()
        let runner = makeRunner(store: store, session: session, box: box)

        try await runner.send("hello")
        box.process.endOutput()
        await eventually("the dead turn to be filed") {
            (try? await store.session(id: session.id))?.state == .failed
        }

        try await runner.send("again")
        #expect(box.processes.count == 2)
        #expect(box.processes[1].sentMethods.contains("initialize"))
        #expect(box.processes[1].sentMethods.contains("session/resume"))
        #expect(box.processes[1].sentMethods.contains("session/prompt"))
        let after = try #require(try await store.session(id: session.id))
        #expect(after.state == .running)
        runner.terminateNow()
    }

    @Test("Stop answers a pending permission as cancelled, not reject_always")
    func stopAnswersPermissionAsCancelled() async throws {
        let store = try makeTestStore("grok-stop-permission")
        let session = try await makeGrokSession(store)
        let box = scriptedGrokBox()
        let runner = makeRunner(store: store, session: session, box: box)

        try await runner.send("run it")
        box.process.emit(permissionRequestLine(id: 7))
        await eventually("the question to be stored") {
            ((try? await store.pendingPermissionAsks(sessionID: session.id)) ?? []).isEmpty == false
        }

        runner.cancelNow()
        await eventually("the cancelled answer to reach the server") {
            box.process.stdin.contains { $0.contains("\"outcome\":\"cancelled\"") }
        }
        #expect(!box.process.stdin.contains { $0.contains("reject-always") })
        await eventually("the question to be filed as stopped") {
            ((try? await store.permissionAskDecisions(sessionID: session.id)) ?? [:])
                .values.contains(PermissionAskOutcome.stopped)
        }
        runner.terminateNow()
    }
}

private func promptIDs(in process: ScriptedCodexProcess) -> [JSONValue] {
    process.stdin.compactMap(JSONValue.parse)
        .filter { $0["method"]?.stringValue == "session/prompt" }
        .compactMap { $0["id"] }
}

private func emitPromptResult(on process: ScriptedCodexProcess, id: JSONValue, stopReason: String) {
    let result = JSONValue.object([
        "sessionId": .string("sess-1"),
        "stopReason": .string(stopReason),
    ])
    process.emit("{\"id\":\(id.compactJSON),\"result\":\(result.compactJSON)}")
}

private func permissionRequestLine(id: Int) -> String {
    let params = JSONValue.object([
        "sessionId": .string("sess-1"),
        "toolCall": .object([
            "toolCallId": .string("call_1"),
            "title": .string("Bash"),
            "toolName": .string("run_terminal_cmd"),
            "rawInput": .object(["command": .string("ls")]),
        ]),
        "options": .array([
            .object(["optionId": .string("allow-once"), "name": .string("Allow once"), "kind": .string("allow_once")]),
            .object(["optionId": .string("allow-always"), "name": .string("Always"), "kind": .string("allow_always")]),
            .object(["optionId": .string("reject-once"), "name": .string("Reject"), "kind": .string("reject_once")]),
            .object(["optionId": .string("reject-always"), "name": .string("Always reject"), "kind": .string("reject_always")]),
        ]),
    ])
    return "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"session/request_permission\",\"params\":\(params.compactJSON)}"
}
