import Testing
import Foundation
@testable import BloomCore

private actor GrokRecoveryEvents {
    var values: [AgentEvent] = []
    func append(_ event: AgentEvent) { values.append(event) }

    func hasText(_ text: String) -> Bool {
        values.contains {
            if case .streamDelta(.text(let value)) = $0 { return value == text }
            return false
        }
    }
}

private func recoveryWait(_ condition: @Sendable () async -> Bool) async throws {
    for _ in 0..<300 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Grok recovery timed out")
}

private func recoverySession(_ store: Store) async throws -> Session {
    let repo = try await store.upsert(Repo(name: "r", path: "/tmp/recovery-\(UUID())"))
    let workspace = try await store.upsert(Workspace(
        repoID: repo.id, name: "w", branch: "b", path: "/tmp/w", baseBranch: "main"
    ))
    return try await store.upsert(Session(workspaceID: workspace.id, model: "grok-4.6", agentKind: .grok))
}

private func recoveryBox() -> ProcessBox {
    let box = ProcessBox()
    box.reply(to: "initialize", with: .object([:]))
    box.reply(to: "session/new", with: .object(["sessionId": .string("s")]))
    box.reply(to: "session/resume", with: .object(["sessionId": .string("s")]))
    box.ignore("session/prompt")
    return box
}

private func recoveryRunner(_ store: Store, _ session: Session, _ box: ProcessBox) -> GrokRunner {
    GrokRunner(workspacePath: "/tmp/w", session: session, store: store, makeClient: { config in
        GrokClient(configuration: config, makeProcess: box.factory)
    })
}

private func recoveryText(_ process: ScriptedCodexProcess, _ text: String) {
    let params = JSONValue.object(["sessionId": .string("s"), "update": .object([
        "sessionUpdate": .string("agent_message_chunk"), "content": .object(["type": .string("text"), "text": .string(text)])
    ])])
    process.emit(GrokOutgoing.notification(method: "session/update", params: params))
}

private func recoveryComplete(_ process: ScriptedCodexProcess, _ id: JSONValue) {
    process.emit("{\"id\":\(id.compactJSON),\"result\":{\"stopReason\":\"end_turn\"}}")
}

private func recoveryPermission(_ callID: String) -> GrokPermissionRequest {
    GrokPermissionRequest(id: .number(1), sessionID: "s", toolCall: GrokToolCall.decode(.object([
        "toolCallId": .string(callID), "toolName": .string("run_terminal_cmd"),
        "rawInput": .object(["command": .string("ls")])
    ]), isUpdate: false), options: [
        GrokPermissionOption(id: "once", name: "Allow once", kind: "allow_once"),
        GrokPermissionOption(id: "always", name: "Always", kind: "allow_always")
    ], raw: Data())
}

@Suite(.scratchDirectory)
struct GrokRecoveryTests {
    @Test func persistentApprovalSurvivesStorage() throws {
        let ask = GrokPermission.ask(for: recoveryPermission("a"))
        #expect(ask.canWiden)
        let stored = try #require(PermissionAsk.decode(payload: ask.raw))
        #expect(stored.canWiden)
    }

    @Test func resumedPermissionDoesNotInheritPreviousDecision() async throws {
        let store = try makeTestStore("recovery-permission-id")
        let session = try await recoverySession(store)
        let first = GrokPermission.ask(for: recoveryPermission("first"))
        try await store.appendPermissionAsk(sessionID: session.id, ask: first)
        try await store.resolvePermissionAsk(id: first.requestID, decision: "allow")
        let next = GrokPermission.ask(for: recoveryPermission("second"))
        try await store.appendPermissionAsk(sessionID: session.id, ask: next)
        let pending = try await store.pendingPermissionAsks(sessionID: session.id)
        #expect(pending.count == 1)
    }

    @Test func stoppedTextDoesNotJoinNextReply() async throws {
        let store = try makeTestStore("recovery-stop-text")
        let session = try await recoverySession(store)
        let box = recoveryBox()
        let runner = recoveryRunner(store, session, box)
        let events = GrokRecoveryEvents()
        let stream = runner.events
        let pump = Task { for await event in stream { await events.append(event) } }
        defer { runner.terminateNow(); pump.cancel() }
        try await runner.send("first")
        recoveryText(box.process, "OLD")
        try await recoveryWait { await events.hasText("OLD") }
        runner.cancelNow()
        try await recoveryWait { box.process.sentMethods.contains("session/cancel") }
        try await runner.send("second")
        let ids = box.process.stdin.compactMap(JSONValue.parse)
            .filter { $0["method"]?.stringValue == "session/prompt" }
            .compactMap { $0["id"] }
        try #require(ids.count == 2)
        recoveryComplete(box.process, ids[0])
        recoveryText(box.process, "NEW")
        recoveryComplete(box.process, ids[1])
        try await recoveryWait { (try? await store.session(id: session.id))?.state == .idle }
        let rows = try await store.messages(sessionID: session.id)
        let texts = rows.compactMap {
            JSONValue.parse($0.payload)?["message"]?["content"]?.arrayValue?.first?["text"]?.stringValue
        }
        #expect(texts == ["first", "OLD", "second", "NEW"])
    }

    @Test func closedTextIsFlushedBeforeReconnect() async throws {
        let store = try makeTestStore("recovery-close-text")
        let session = try await recoverySession(store)
        let box = recoveryBox()
        let runner = recoveryRunner(store, session, box)
        let events = GrokRecoveryEvents()
        let stream = runner.events
        let pump = Task { for await event in stream { await events.append(event) } }
        defer { runner.terminateNow(); pump.cancel() }
        try await runner.send("first")
        recoveryText(box.process, "OLD")
        try await recoveryWait { await events.hasText("OLD") }
        box.process.endOutput()
        try await recoveryWait { (try? await store.session(id: session.id))?.state == .failed }
        try await runner.send("second")
        recoveryText(box.process, "NEW")
        let prompt = box.process.stdin.compactMap(JSONValue.parse).last {
            $0["method"]?.stringValue == "session/prompt"
        }
        let id = try #require(prompt?["id"])
        recoveryComplete(box.process, id)
        try await recoveryWait { (try? await store.session(id: session.id))?.state == .idle }
        let rows = try await store.messages(sessionID: session.id)
        let texts = rows.compactMap {
            JSONValue.parse($0.payload)?["message"]?["content"]?.arrayValue?.first?["text"]?.stringValue
        }
        #expect(texts == ["first", "OLD", "second", "NEW"])
    }
}
