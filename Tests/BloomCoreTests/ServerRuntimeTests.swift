import Foundation
import Synchronization
import Testing
@testable import BloomCore

@Suite("ServerRuntime", .tags(.persistence, .subprocess), .scratchDirectory)
struct ServerRuntimeTests {
    @Test func concurrentRetriesLaunchOneTurn() async throws {
        let fixture = try await ServerFixture()
        let runtime = fixture.runtime()
        let request = ServerRequest(.send(sessionID: fixture.session.id, text: "First turn"))
        async let first = runtime.respond(to: request)
        async let second = runtime.respond(to: request)
        let replies = await [first, second]
        for reply in replies { #expect(reply.isAccepted) }
        #expect(await fixture.runner.sends == ["First turn"])

        let changed = await runtime.respond(to: ServerRequest(.stop(sessionID: fixture.session.id), id: request.id))
        #expect(changed.failure?.contains("reused") == true)
        #expect(fixture.runner.stops.withLock { $0 } == 0)
        await runtime.shutdown()
    }

    @Test func distinctPromptsCannotRaceIntoOneRunner() async throws {
        let fixture = try await ServerFixture()
        let runtime = fixture.runtime()
        async let first = runtime.respond(to: ServerRequest(.send(sessionID: fixture.session.id, text: "One")))
        async let second = runtime.respond(to: ServerRequest(.send(sessionID: fixture.session.id, text: "Two")))
        let replies = await [first, second]
        #expect(replies.filter(\.isAccepted).count == 1)
        #expect(replies.contains { $0.failure?.contains("busy") == true })
        #expect(await fixture.runner.sends.count == 1)
        await runtime.shutdown()
    }

    @Test func disconnectLeavesAgentAliveAndAnotherClientCanContinue() async throws {
        let fixture = try await ServerFixture()
        let runner = fixture.runner
        let daemon = try await ServerDaemon.start(directory: fixture.directory, makeRunner: { _, _, _ in runner })
        let first = try await ServerClient.connect(to: .local(directory: fixture.directory))
        _ = try await first.request(ServerRequest(.send(sessionID: fixture.session.id, text: "Keep working")))
        await first.disconnect()
        #expect(runner.terminated.withLock { $0 } == false)

        let second = try await ServerClient.connect(to: .local(directory: fixture.directory))
        let reply = try await second.request(ServerRequest(.transcript(sessionID: fixture.session.id, afterSeq: -1)))
        guard case .transcript(let transcript) = reply.result else { Issue.record("Missing transcript"); return }
        #expect(transcript.isBusy)
        #expect(transcript.messages.count == 1)
        await runner.finish()
        await waitUntil("finished turn reaches runtime") {
            let reply = await daemon.runtime.respond(to: ServerRequest(.transcript(sessionID: fixture.session.id, afterSeq: -1)))
            if case .transcript(let transcript) = reply.result { return !transcript.isBusy }
            return false
        }
        _ = try await second.request(ServerRequest(.send(sessionID: fixture.session.id, text: "Continue")))
        #expect(await runner.sends == ["Keep working", "Continue"])
        await second.disconnect()
        await daemon.shutdown()
        #expect(runner.terminated.withLock { $0 })
    }

    @Test func completedCommandIsNotReplayedAfterServerRestart() async throws {
        let fixture = try await ServerFixture()
        let first = fixture.runtime()
        let request = ServerRequest(.send(sessionID: fixture.session.id, text: "Do this once"))
        let reply = await first.respond(to: request)
        #expect(reply.isAccepted)
        await first.shutdown()
        let second = fixture.runtime()
        let replay = await second.respond(to: request)
        #expect(replay.isAccepted)
        #expect(await fixture.runner.sends.count == 1)
        await second.shutdown()
    }

    @Test func interruptedCommandRequiresInspectionInsteadOfReplay() async throws {
        let fixture = try await ServerFixture()
        let request = ServerRequest(.send(sessionID: fixture.session.id, text: "Uncertain outcome"))
        let record = try JSONEncoder().encode(ServerCommandRecord(request: request))
        try await fixture.store.setSetting("server.command.\(request.id.uuidString)", String(decoding: record, as: UTF8.self))
        let runtime = fixture.runtime()
        let reply = await runtime.respond(to: request)
        #expect(reply.failure?.contains("Inspect") == true)
        #expect(await fixture.runner.sends.isEmpty)
        await runtime.shutdown()
    }

    @Test func staleAndConcurrentApprovalsAreRefused() async throws {
        let fixture = try await ServerFixture()
        let runtime = fixture.runtime()
        _ = await runtime.respond(to: ServerRequest(.send(sessionID: fixture.session.id, text: "Wait")))
        let raw = Data(#"{"type":"control_request","request_id":"question-1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"pwd"}}}"#.utf8)
        let ask = try #require(PermissionAsk.decode(payload: raw))
        try await fixture.store.appendPermissionAsk(sessionID: fixture.session.id, ask: ask)
        let operation = ServerOperation.answer(sessionID: fixture.session.id, requestID: ask.requestID, answer: .allowOnce)
        async let first = runtime.respond(to: ServerRequest(operation))
        async let second = runtime.respond(to: ServerRequest(operation))
        let replies = await [first, second]
        #expect(replies.filter(\.isAccepted).count == 1)
        #expect(await fixture.runner.answers == 1)
        let stale = await runtime.respond(to: ServerRequest(operation))
        #expect(stale.failure != nil)
        await runtime.shutdown()
    }

    @Test func protocolMismatchCannotExecuteACommand() async throws {
        let fixture = try await ServerFixture()
        let runtime = fixture.runtime()
        let reply = await runtime.respond(to: ServerRequest(.send(sessionID: fixture.session.id, text: "No"), version: 999))
        #expect(reply.failure?.contains("protocol") == true)
        #expect(await fixture.runner.sends.isEmpty)
        await runtime.shutdown()
    }

    @Test func secondServerCannotResetLiveStateOrReplaceSocket() async throws {
        let fixture = try await ServerFixture()
        let directory = fixture.directory
        let runner = fixture.runner
        let first = try await ServerDaemon.start(directory: directory, makeRunner: { _, _, _ in runner })
        _ = await first.runtime.respond(to: ServerRequest(.send(sessionID: fixture.session.id, text: "Working")))
        do {
            _ = try await ServerDaemon.start(directory: directory)
            Issue.record("A second server acquired the same data directory")
        } catch { #expect(error.localizedDescription.contains("already owns")) }
        let state = try await fixture.store.session(id: fixture.session.id)?.state
        #expect(state == .running)
        let client = try await ServerClient.connect(to: .local(directory: directory))
        let reply = try await client.request(ServerRequest(.catalogue))
        if case .catalogue = reply.result {} else { Issue.record("First server lost its socket") }
        await client.disconnect()
        await first.shutdown()
    }

    @Test func stoppedClaudeTurnDoesNotRequireAResultEvent() async throws {
        let fixture = try await ServerFixture()
        fixture.runner.emitsStopResult.withLock { $0 = false }
        let runtime = fixture.runtime()
        _ = await runtime.respond(to: ServerRequest(.send(sessionID: fixture.session.id, text: "First")))
        _ = await runtime.respond(to: ServerRequest(.stop(sessionID: fixture.session.id)))
        await waitUntil("cancelled state is stored") {
            (try? await fixture.store.session(id: fixture.session.id)?.state) == .cancelled
        }
        let second = await runtime.respond(to: ServerRequest(.send(sessionID: fixture.session.id, text: "Second")))
        #expect(second.isAccepted)
        #expect(await fixture.runner.sends == ["First", "Second"])
        await runtime.shutdown()
    }

    @Test func stopWaitsForAnAcceptedSendBeforeSignallingTheRunner() async throws {
        let fixture = try await ServerFixture()
        let runtime = fixture.runtime()
        let send = Task { await runtime.respond(to: ServerRequest(.send(sessionID: fixture.session.id, text: "Starting"))) }
        await waitUntil("send reaches the runner") { await fixture.runner.sends.count == 1 }
        let stopped = await runtime.respond(to: ServerRequest(.stop(sessionID: fixture.session.id)))
        let sent = await send.value
        #expect(stopped.isAccepted)
        #expect(sent.isAccepted)
        #expect(fixture.runner.stops.withLock { $0 } == 1)
        await runtime.shutdown()
    }

    @Test func dataDirectoryMustBePrivate() async throws {
        let directory = TestScratch.path("public-server")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory)
        do {
            _ = try await ServerDaemon.start(directory: directory)
            Issue.record("Server accepted a public data directory")
        } catch { #expect(error.localizedDescription.contains("700")) }
        #expect(!FileManager.default.fileExists(atPath: ServerDaemon.databasePath(directory: directory)))
    }

    @Test func remoteCommandQuotesPathsAndRefusesSSHOptions() throws {
        let endpoint = ServerEndpoint.ssh(host: "developer@buildbox", executable: "/opt/Bloom's tools/bloom-server", directory: "/tmp/$(touch bad)")
        let proposedLaunch = try endpoint.launch
        let launch = try #require(proposedLaunch)
        #expect(launch.executable == "/usr/bin/ssh")
        #expect(launch.arguments.contains("StrictHostKeyChecking=yes"))
        #expect(launch.arguments.last == "'/opt/Bloom'\\''s tools/bloom-server' 'connect' '--data-dir' '/tmp/$(touch bad)'")
        #expect(throws: ServerFailure.self) {
            _ = try ServerEndpoint.ssh(host: "-oProxyCommand=bad", executable: "/bin/server", directory: "/tmp/data").launch
        }
    }
}

private extension ServerReply {
    var isAccepted: Bool { if case .accepted = result { return true }; return false }
    var failure: String? { if case .failure(let text) = result { return text }; return nil }
}

private struct ServerFixture {
    let directory: String
    let store: Store
    let session: Session
    let runner: ServerTestRunner

    init() async throws {
        directory = TestScratch.unique("server")
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        store = try Store(path: ServerDaemon.databasePath(directory: directory))
        let repo = try await store.upsert(Repo(name: "Fixture", path: directory))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "Fixture", branch: "fixture", path: directory, baseBranch: "main"
        ))
        session = try await store.upsert(Session(workspaceID: workspace.id))
        runner = ServerTestRunner(sessionID: session.id, store: store)
    }

    func runtime() -> ServerRuntime {
        let runner = runner
        return ServerRuntime(store: store, makeRunner: { _, _, _ in runner })
    }
}

private actor ServerTestRunner: SessionRunner {
    nonisolated let agentKind = AgentKind.claudeCode
    nonisolated let terminated = Mutex(false)
    nonisolated let stops = Mutex(0)
    nonisolated let emitsStopResult = Mutex(true)
    nonisolated let sink = EventFanout<AgentEvent>()
    nonisolated var events: AsyncStream<AgentEvent> { sink.stream() }
    var isProcessAlive: Bool { !terminated.withLock { $0 } }
    private(set) var sends: [String] = []
    private(set) var answers = 0
    let sessionID: SessionID
    let store: Store

    init(sessionID: SessionID, store: Store) { self.sessionID = sessionID; self.store = store }

    func send(_ text: String, recording: Data?) async throws {
        sends.append(text)
        _ = try await store.appendNext(sessionID: sessionID, kind: .user, payload: Data(text.utf8))
        _ = try await store.update(sessionID: sessionID) { $0.apply(.turnStarted) }
        try await Task.sleep(for: .milliseconds(20))
    }

    nonisolated func cancelNow() {
        stops.withLock { $0 += 1 }
        if emitsStopResult.withLock({ $0 }) { sink.yield(.result(AgentResult())) } else { Task { await recordStop() } }
    }

    private func recordStop() async {
        _ = try? await store.update(sessionID: sessionID) { $0.apply(.cancelled) }
    }
    nonisolated func terminateNow() { terminated.withLock { $0 = true } }

    func answer(requestID: String, decision: PermissionDecision) async {
        answers += 1
        try? await store.resolvePermissionAsk(id: requestID, decision: decision.storedName)
    }

    func finish() async {
        _ = try? await store.update(sessionID: sessionID) { $0.apply(.turnFinished(isError: false)) }
        sink.yield(.result(AgentResult()))
    }
}
