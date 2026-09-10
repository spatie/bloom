import Foundation
import Testing
@testable import BloomCore

@Suite("Archive admission across RPC and MCP", .scratchDirectory, .tags(.subprocess, .persistence))
struct ServerArchiveAdmissionTests {
    @Test func archiveWaitsForAnAgentStartPausedBeforeItsFirstStoreWrite() async throws {
        let repo = try await TempRepo()
        try repo.write(".bloom/settings.toml", "[git]\ndelete_branch_on_archive = false\n")
        try await repo.commit("Keep archived branches")
        let store = try makeTestStore("archive-admission")
        let manager = WorkspaceManager(store: store)
        let project = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(repo: project, prompt: "Admission fixture")
        let parent = try await store.upsert(Session(workspaceID: workspace.id, title: "Parent"))
        let discovery = AdmissionGate(), sending = AdmissionGate()
        let admissions = ServerWorkspaceAdmissions()
        let runtime = ServerRuntime(store: store, installedAgents: { _ in await discovery.hold(); return [.claudeCode] },
                                    makeRunner: { _, _, _ in AdmissionRunner(gate: sending) }, workspaceAdmissions: admissions)
        do {
            let bridge = try await runtime.startBridge(socketPath: BridgeSocketPath.derive(databasePath: store.path, directory: "/tmp"))
            let attachment = bridge.attach(session: parent, workspace: workspace, shimPath: "/fixture/bloom-bridge")
            let client = try UnixSocketConnection.connect(to: bridge.socketPath)
            defer { client.close() }
            var lines = client.lines.makeAsyncIterator()
            client.writeLine(String(decoding: try JSONEncoder().encode(BridgeHello(token: attachment.token, role: "parent")), as: UTF8.self))
            _ = try #require(await lines.next())
            let checked = await runtime.respond(to: ServerRequest(.workspace(workspaceID: workspace.id, action: .archivePreview)))
            guard case .archivePreview(let preview) = checked.result else { throw ServerFailure("Missing archive fixture preview") }
            client.writeLine(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"agent_start","arguments":{"name":"research","task":"Read the project"}}}"#)
            await discovery.waitForStart()
            let archiving = Task { await runtime.respond(to: ServerRequest(.workspace(workspaceID: workspace.id, action: .archive(confirmation: preview.id)))) }
            await waitUntil("archive drains the admitted MCP operation") { admissions.waitingCount == 1 }
            #expect(FileManager.default.fileExists(atPath: workspace.path))
            #expect(try await store.crew(of: parent.id).isEmpty)
            await discovery.release()
            let started = try #require(await lines.next())
            #expect(JSONValue.parse(Data(started.utf8))?["result"]?["isError"] != .bool(true))
            let reply = await archiving.value
            if case .accepted = reply.result { Issue.record("Archive discarded work queued by an accepted MCP call") }
            #expect(try await store.crew(of: parent.id).count == 1)
            #expect(try await store.workspace(id: workspace.id)?.state == .active)
            #expect(FileManager.default.fileExists(atPath: workspace.path))
            await sending.release()
            await runtime.shutdown()
        } catch {
            await discovery.release(); await sending.release()
            await runtime.shutdown()
            throw error
        }
    }
}

private actor AdmissionGate {
    private var started = false, released = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var startWait: CheckedContinuation<Void, Never>?
    func hold() async {
        started = true; startWait?.resume(); startWait = nil
        if !released { await withCheckedContinuation { held.append($0) } }
    }
    func waitForStart() async { if !started { await withCheckedContinuation { startWait = $0 } } }
    func release() { released = true; let pending = held; held.removeAll(); for waiter in pending { waiter.resume() } }
}

private actor AdmissionRunner: SessionRunner {
    nonisolated let agentKind = AgentKind.claudeCode
    nonisolated let sink = EventFanout<AgentEvent>()
    nonisolated var events: AsyncStream<AgentEvent> { sink.stream() }
    let gate: AdmissionGate
    var isProcessAlive: Bool { false }
    init(gate: AdmissionGate) { self.gate = gate }
    func send(_ text: String, recording: Data?) async throws { await gate.hold() }
    nonisolated func cancelNow() {}
    nonisolated func terminateNow() {}
    func answer(requestID: String, decision: PermissionDecision) {}
}
