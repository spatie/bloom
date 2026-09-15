import Foundation
import Synchronization
import Testing
@testable import BloomCore

@Suite(.scratchDirectory)
struct ServerAgentAuthenticationTests {
    @Test func statusDistinguishesSavedLoginMissingLoginAndUnknownFailures() {
        #expect(ServerAgentAuthentication.classify(agent: .codex, status: 0, output: "Logged in using ChatGPT").state == .ready)
        #expect(ServerAgentAuthentication.classify(agent: .codex, status: 1, output: "Not logged in").state == .signInRequired)
        #expect(ServerAgentAuthentication.classify(agent: .codex, status: 1, output: "error: unexpected argument 'status'").state == .unknown)
        #expect(ServerAgentAuthentication.classify(agent: .claudeCode, status: 1, output: #"{"loggedIn":false}"#).state == .signInRequired)
        #expect(ServerAgentAuthentication.classify(agent: .claudeCode, status: 0, output: #"{"loggedIn":true,"authMethod":"api_key"}"#).state == .ready)
        #expect(ServerAgentAuthentication.classify(agent: .claudeCode, status: 1, output: "Network unavailable").state == .unknown)
        #expect(AgentAuthenticationStatus.isSignInFailure("Unexpected status 401 Unauthorized"))
        #expect(AgentAuthenticationStatus.isSignInFailure("Refresh token has expired"))
        #expect(!AgentAuthenticationStatus.isSignInFailure("Failed to read line 401 of the source file"))
    }

    @Test func missingLoginRefusesBeforeResolvingOrCreatingARepository() async throws {
        let store = try makeTestStore("auth-before-create")
        let runtime = ServerRuntime(store: store, authentication: { agent, _, _ in .init(agent: agent, state: .signInRequired) }, installedAgents: { _ in [.codex] })
        var request = ServerWorkspaceRequest(repositoryPath: "/not-a-cloned-repository", name: "Keep this prompt", agent: .codex, model: "fixture")
        request.mode = .chat; request.prompt = "Keep this prompt"
        let reply = await runtime.respond(to: ServerRequest(.create(request)))
        guard case .failure(let reason) = reply.result else { Issue.record("Unauthenticated creation succeeded"); await runtime.shutdown(); return }
        #expect(AgentAuthenticationStatus.isSignInFailure(reason))
        #expect(try await store.repos().isEmpty)
        #expect(try await store.workspaces().isEmpty)
        await runtime.shutdown()
    }

    @Test func cloneOnlyCreationDoesNotCheckAgentAuthentication() async throws {
        let repo = try await TempRepo()
        let store = try makeTestStore("auth-clone-only")
        let probes = Mutex(0)
        let runtime = ServerRuntime(store: store, authentication: { agent, _, _ in probes.withLock { $0 += 1 }; return .init(agent: agent, state: .signInRequired) }, installedAgents: { _ in [] })
        var request = ServerWorkspaceRequest(repositoryPath: repo.path, name: "Clone only", agent: .codex, model: "fixture")
        request.mode = .terminal; request.runSetupScript = false
        let reply = await runtime.respond(to: ServerRequest(.create(request)))
        guard case .creation(.workspaceStarted(let workspace, let session, _, _)) = reply.result else {
            Issue.record("Clone-only creation failed: \(String(describing: reply.result))"); await runtime.shutdown(); return
        }
        defer { try? FileManager.default.removeItem(atPath: workspace.path) }
        #expect(session == nil)
        #expect(probes.withLock { $0 } == 0)
        await runtime.shutdown()
    }

    @Test func authenticationPauseRetriesTheSameDeliveryOnceAfterSignIn() async throws {
        let fixture = try await fixture()
        let ready = Mutex(false), loads = Mutex(0)
        let runner = AuthenticationRunner()
        let live = ServerSession(runner: runner)
        let queue = ServerPromptQueue(store: fixture.store, load: { _ in
            loads.withLock { $0 += 1 }
            guard ready.withLock({ $0 }) else { throw AgentAuthenticationRequired(agent: .codex) }
            return live
        })
        try await queue.enqueue("original prompt", sessionID: fixture.chat.id)
        await waitUntil("authentication pause") { (try? await fixture.store.setting(ServerPromptQueue.pauseKey(fixture.chat.id))) == "true" }
        let pending = try #require(try await fixture.store.pendingDeliveries(sessionID: fixture.chat.id).first)
        let count = loads.withLock { $0 }
        try await Task.sleep(for: .milliseconds(40))
        #expect(loads.withLock { $0 } == count)
        await queue.shutdown()
        let restored = ServerPromptQueue(store: fixture.store, load: { _ in
            guard ready.withLock({ $0 }) else { throw AgentAuthenticationRequired(agent: .codex) }
            return live
        })
        try await restored.restore()
        let restoredState = try await restored.snapshot(fixture.chat.id)
        #expect(restoredState.0.map(\.id) == [pending.id])
        #expect(restoredState.1.map(AgentAuthenticationStatus.isSignInFailure) == true)
        ready.withLock { $0 = true }
        try await restored.retryAuthenticationPaused(sessionID: fixture.chat.id, deliveryID: pending.id, text: pending.body)
        await waitUntil("one original delivery") { await runner.sends.count == 1 }
        await waitUntil("queue delivery settled") { (try? await fixture.store.pendingDeliveries(sessionID: fixture.chat.id).isEmpty) == true }
        #expect(await runner.sends == ["original prompt"])
        await #expect(throws: ServerFailure.self) { try await restored.retryAuthenticationPaused(sessionID: fixture.chat.id, deliveryID: pending.id, text: pending.body) }
        await restored.shutdown(); await live.shutdown()
    }

    @Test func cancelledAndUncertainDeliveriesCannotBeRetriedOrResurrected() async throws {
        let fixture = try await fixture()
        let delivery = try await fixture.store.enqueueDelivery(Delivery(targetSessionID: fixture.chat.id, body: "same"))
        try await fixture.store.setSetting(ServerPromptQueue.authenticationPauseKey(fixture.chat.id), AgentKind.codex.rawValue)
        try await fixture.store.setSetting(ServerPromptQueue.pauseKey(fixture.chat.id), "true")
        try await fixture.store.setSetting("server.delivery." + delivery.id.rawValue, "started")
        let resumedUncertain = try await fixture.store.resumeAuthenticationPausedDelivery(sessionID: fixture.chat.id, deliveryID: delivery.id, matching: "same")
        #expect(!resumedUncertain)
        try await fixture.store.setSetting("server.delivery." + delivery.id.rawValue, nil)
        try await fixture.store.cancelDelivery(id: delivery.id)
        let resumedCancelled = try await fixture.store.resumeAuthenticationPausedDelivery(sessionID: fixture.chat.id, deliveryID: delivery.id, matching: "same")
        #expect(!resumedCancelled)
        #expect(try await fixture.store.pendingDeliveries(sessionID: fixture.chat.id).isEmpty)
    }

    @Test func ordinaryIdenticalSendsRemainDistinct() async throws {
        let fixture = try await fixture()
        let queue = ServerPromptQueue(store: fixture.store, load: { _ in throw AgentAuthenticationRequired(agent: .codex) })
        try await queue.enqueue("same", sessionID: fixture.chat.id)
        try await queue.enqueue("same", sessionID: fixture.chat.id)
        let pending = try await fixture.store.pendingDeliveries(sessionID: fixture.chat.id)
        #expect(pending.count == 2)
        #expect(Set(pending.map(\.id)).count == 2)
        await queue.shutdown()
    }

    @Test func independentChecksAreBoundedAndRetainAgentOrder() async throws {
        let store = try makeTestStore("auth-parallel")
        let gate = AuthenticationProbeGate()
        let agents: [AgentKind] = [.codex, .claudeCode, .codex]
        let work = Task { await ServerAgentAuthentication.checkAll(agents, store: store) { agent, _, _ in await gate.probe(agent) } }
        await waitUntil("two authentication probes") { await gate.started == 2 }
        #expect(await gate.maximumActive == 2)
        await gate.release()
        let statuses = await work.value
        #expect(statuses.map(\.agent) == agents)
        #expect(await gate.maximumActive == 2)
        #expect(await gate.started == 3)
    }

    private func fixture() async throws -> (store: Store, chat: Session) {
        let store = try makeTestStore("auth-queue")
        let repo = try await store.upsert(Repo(name: "Fixture", path: "/fixture"))
        let workspace = try await store.upsert(Workspace(repoID: repo.id, name: "Fixture", branch: "fixture", path: "/fixture", baseBranch: "main"))
        let chat = try await store.upsert(Session(workspaceID: workspace.id))
        return (store, chat)
    }
}

private actor AuthenticationRunner: SessionRunner {
    nonisolated let agentKind = AgentKind.codex
    nonisolated var events: AsyncStream<AgentEvent> { AsyncStream { $0.finish() } }
    var isProcessAlive: Bool { false }
    private(set) var sends: [String] = []
    func send(_ text: String, recording: Data?) { sends.append(text) }
    nonisolated func cancelNow() {}
    nonisolated func terminateNow() {}
    func answer(requestID: String, decision: PermissionDecision) {}
}

private actor AuthenticationProbeGate {
    private var active = 0
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var started = 0
    private(set) var maximumActive = 0
    func probe(_ agent: AgentKind) async -> AgentAuthenticationStatus {
        active += 1; started += 1; maximumActive = max(maximumActive, active)
        if !released { await withCheckedContinuation { waiting.append($0) } }
        active -= 1
        return .init(agent: agent, state: .ready)
    }
    func release() {
        released = true
        let held = waiting
        waiting = []
        held.forEach { $0.resume() }
    }
}
