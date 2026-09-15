import Foundation
import Testing
@testable import BloomCore

@Suite("Server crew turn settlement", .tags(.persistence), .scratchDirectory)
struct ServerCrewQueueTests {
    @Test func immediateResultWaitsForTheDeliveryReceiptAndKeepsCrewRecording() async throws {
        let gate = CrewSendGate()
        let fixture = try await CrewQueueFixture(immediate: "already done", gate: gate)
        let message = CrewMessage.said(from: "reviewer", text: "Looks good", sender: .subagent)
        try await fixture.queue.enqueue(Delivery(targetSessionID: fixture.session.id, kind: .message, crew: message))
        await waitUntil("the result arrives while send is still suspended") { await fixture.relay.observed == 1 }
        #expect(await fixture.relay.settled.isEmpty)
        #expect(try await fixture.store.pendingDeliveries(sessionID: fixture.session.id).count == 1)
        await gate.open()
        await waitUntil("the settled report follows the receipt") { await fixture.relay.settled.count == 1 }
        #expect(await fixture.relay.settled == [.completed("already done")])
        #expect(try await fixture.store.pendingDeliveries(sessionID: fixture.session.id).isEmpty)
        #expect(await fixture.runner.texts == [message.sent])
        let firstRecording = try #require(await fixture.runner.recordings.first)
        let recording = try #require(firstRecording)
        #expect(CrewMessage.decode(recording) == message)
        await fixture.shutdown()
    }

    @Test func queuedFollowupRunsBeforeReportingTheFinalAnswer() async throws {
        let fixture = try await CrewQueueFixture()
        try await fixture.queue.enqueue("first", sessionID: fixture.session.id)
        await waitUntil("first started") { await fixture.runner.texts.count == 1 }
        try await fixture.queue.enqueue("followup", sessionID: fixture.session.id)
        await fixture.runner.finish("outdated answer")
        await waitUntil("followup started") { await fixture.runner.texts.count == 2 }
        #expect(await fixture.relay.settled.isEmpty)
        await fixture.runner.finish("final answer")
        await waitUntil("final answer reported") { await fixture.relay.settled.count == 1 }
        #expect(await fixture.relay.settled == [.completed("final answer")])
        await fixture.shutdown()
    }

    @Test func failurePausesFollowupsAndLateResultDoesNotReportTwice() async throws {
        let fixture = try await CrewQueueFixture()
        try await fixture.queue.enqueue("first", sessionID: fixture.session.id)
        await waitUntil("first started") { await fixture.runner.texts.count == 1 }
        try await fixture.queue.enqueue("followup", sessionID: fixture.session.id)
        fixture.runner.sink.yield(.error(AgentError(message: "authentication failed")))
        fixture.runner.sink.yield(.result(AgentResult(summary: "late result")))
        await waitUntil("failure reported") { await fixture.relay.settled.count == 1 }
        #expect(await fixture.relay.settled == [.failed("authentication failed")])
        #expect(await fixture.runner.texts == ["first"])
        #expect(try await fixture.store.pendingDeliveries(sessionID: fixture.session.id).map(\.body) == ["followup"])
        #expect(try await fixture.queue.snapshot(fixture.session.id).1 == "authentication failed")
        await fixture.shutdown()
    }

    @Test func autonomousReportsDoNotResumeAPausedParent() async throws {
        let fixture = try await CrewQueueFixture()
        try await fixture.queue.pause(fixture.session.id)
        try await fixture.queue.enqueue(Delivery(targetSessionID: fixture.session.id, kind: .report,
                                                 crew: .stopped(name: "reviewer", lastMessage: "done")))
        let queued = try await fixture.queue.snapshot(fixture.session.id)
        #expect(queued.0.count == 1)
        #expect(queued.1?.contains("paused") == true)
        #expect(await fixture.runner.texts.isEmpty)
        #expect(try await fixture.store.setting("server.queue.paused." + fixture.session.id.rawValue) == "true")
        await fixture.shutdown()
    }

    @Test func storedIdleCannotReleaseTheTurnBeforeItsResultArrives() async throws {
        let fixture = try await CrewQueueFixture()
        try await fixture.live.send("first")
        _ = try await fixture.store.update(sessionID: fixture.session.id) { $0.apply(.turnFinished(isError: false)) }
        try await fixture.live.refreshState(store: fixture.store, sessionID: fixture.session.id)
        #expect(await fixture.live.isBusy)
        await fixture.runner.finish("done")
        await waitUntil("result releases turn") { await !fixture.live.isBusy }
        #expect(await fixture.relay.observed == 1)
        await fixture.shutdown()
    }

    @Test func runnerCreationFailureReportsAndPausesInsteadOfStrandingTheOrchestrator() async throws {
        let store = try makeTestStore("crew-launch-refusal")
        let session = try await store.upsert(Session(workspaceID: nil))
        let relay = CrewQueueRelay()
        let queue = ServerPromptQueue(store: store, load: { _ in throw ServerFailure("Agent executable is unavailable") },
                                      settled: { _, ending in await relay.record(ending) })
        try await queue.enqueue("start", sessionID: session.id)
        await waitUntil("runner creation failure reported") { await relay.settled.count == 1 }
        #expect(await relay.settled == [.failed("Agent executable is unavailable")])
        #expect(try await store.setting("server.queue.paused." + session.id.rawValue) == "true")
        #expect(try await store.pendingDeliveries(sessionID: session.id).count == 1)
        await queue.shutdown()
    }

    @Test func sharedReportPolicyAndClaimKeepMacAndServerEndingsConsistent() {
        #expect(CrewTurnEnd.completed("old").report(name: "crew", continuing: true) == nil)
        #expect(CrewTurnEnd.completed("done").report(name: "crew", continuing: false)?.event == .stopped)
        #expect(CrewTurnEnd.failed("broken").report(name: "crew", continuing: true)?.event == .failed)
        var claim = CrewTurnReportClaim()
        let first = claim.claim(), repeated = claim.claim()
        #expect(first)
        #expect(!repeated)
        claim.start()
        let next = claim.claim()
        #expect(next)
    }
}

private struct CrewQueueFixture {
    let store: Store
    let session: Session
    let live: ServerSession
    let runner: CrewQueueRunner
    let queue: ServerPromptQueue
    let relay: CrewQueueRelay

    init(immediate: String? = nil, gate: CrewSendGate? = nil) async throws {
        store = try makeTestStore("crew-queue")
        session = try await store.upsert(Session(workspaceID: nil))
        runner = CrewQueueRunner(immediate: immediate, gate: gate)
        let relay = CrewQueueRelay()
        self.relay = relay
        let live = ServerSession(runner: runner) { ending in await relay.receive(ending) }
        self.live = live
        queue = ServerPromptQueue(store: store, load: { _ in live }, settled: { _, ending in await relay.record(ending) })
        await relay.bind(queue, sessionID: session.id)
    }

    func shutdown() async { await queue.shutdown(); await live.shutdown() }
}

private actor CrewQueueRelay {
    private weak var queue: ServerPromptQueue?
    private var sessionID: SessionID?
    private(set) var observed = 0
    private(set) var settled: [CrewTurnEnd] = []
    func bind(_ queue: ServerPromptQueue, sessionID: SessionID) { self.queue = queue; self.sessionID = sessionID }
    func receive(_ ending: CrewTurnEnd) async {
        observed += 1
        if let sessionID { await queue?.turnEnded(sessionID, ending: ending) }
    }
    func record(_ ending: CrewTurnEnd) { settled.append(ending) }
}

private actor CrewQueueRunner: SessionRunner {
    nonisolated let agentKind = AgentKind.claudeCode
    nonisolated let sink = EventFanout<AgentEvent>()
    nonisolated var events: AsyncStream<AgentEvent> { sink.stream() }
    var isProcessAlive: Bool { false }
    let immediate: String?
    let gate: CrewSendGate?
    private(set) var texts: [String] = []
    private(set) var recordings: [Data?] = []
    init(immediate: String?, gate: CrewSendGate?) { self.immediate = immediate; self.gate = gate }
    func send(_ text: String, recording: Data?) async throws {
        texts.append(text); recordings.append(recording)
        if let immediate { sink.yield(.result(AgentResult(summary: immediate))) }
        await gate?.wait()
    }
    func finish(_ text: String) { sink.yield(.result(AgentResult(summary: text))) }
    nonisolated func cancelNow() {}
    nonisolated func terminateNow() {}
    func answer(requestID: String, decision: PermissionDecision) {}
}

private actor CrewSendGate {
    private var opened = false
    private var waiting: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func open() { opened = true; waiting?.resume(); waiting = nil }
}
