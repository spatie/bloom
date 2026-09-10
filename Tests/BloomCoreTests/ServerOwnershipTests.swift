import Foundation
import Synchronization
import Testing
@testable import BloomCore

@Suite("Daemon ownership drain", .tags(.persistence), .scratchDirectory)
struct ServerOwnershipTests {
    @Test func concurrentShutdownKeepsOwnershipUntilRunnerCleanupCompletes() async throws {
        let fixture = try await OwnershipFixture()
        let daemon = try await fixture.start()
        _ = await daemon.runtime.respond(to: ServerRequest(.send(sessionID: fixture.session.id, text: "start fixture")))
        await fixture.runner.gate.waitForStart()
        let first = Task { await daemon.shutdown() }, second = Task { await daemon.shutdown() }
        await fixture.runner.gate.waitForTermination()
        await #expect(throws: ServerFailure.self) { try await fixture.start() }
        fixture.runner.allowExit()
        await first.value; await second.value
        // The stopped daemon value is still alive here. Ownership ends with its awaited cleanup,
        // not an arbitrary later ARC release.
        let replacement = try await fixture.start()
        await replacement.shutdown()
    }

    @Test func droppingADaemonStillRetainsOwnershipWhileCleanupRuns() async throws {
        let fixture = try await OwnershipFixture()
        var daemon: ServerDaemon? = try await fixture.start()
        _ = await daemon?.runtime.respond(to: ServerRequest(.send(sessionID: fixture.session.id, text: "start fixture")))
        await fixture.runner.gate.waitForStart()
        daemon = nil
        await fixture.runner.gate.waitForTermination()
        await #expect(throws: ServerFailure.self) { try await fixture.start() }
        fixture.runner.allowExit()
        await waitUntil("daemon deinit releases ownership after cleanup") {
            do {
                let replacement = try await fixture.start()
                await replacement.shutdown()
                return true
            } catch { return false }
        }
    }
}

private struct OwnershipFixture: Sendable {
    let directory: String
    let store: Store
    let session: Session
    let runner = HeldShutdownRunner()
    init() async throws {
        directory = TestScratch.unique("server-ownership")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        store = try Store(path: ServerDaemon.databasePath(directory: directory))
        let repo = try await store.upsert(Repo(name: "Fixture", path: directory))
        let workspace = try await store.upsert(Workspace(repoID: repo.id, name: "Fixture", branch: "main", path: directory, baseBranch: "main"))
        session = try await store.upsert(Session(workspaceID: workspace.id))
    }
    func start() async throws -> ServerDaemon {
        try await ServerDaemon.start(directory: directory, installedAgents: { _ in [.claudeCode] }, makeRunner: { [runner] _, _, _ in runner })
    }
}

private actor HeldShutdownRunner: SessionRunner {
    nonisolated let agentKind = AgentKind.claudeCode
    nonisolated let sink = EventFanout<AgentEvent>()
    nonisolated var events: AsyncStream<AgentEvent> { sink.stream() }
    nonisolated let gate = OwnershipRunnerGate()
    private nonisolated let exitAllowed = Mutex(false)
    var isProcessAlive: Bool { !exitAllowed.withLock { $0 } }
    func send(_ text: String, recording: Data?) async throws { await gate.started() }
    nonisolated func cancelNow() {}
    nonisolated func terminateNow() { Task { await gate.terminated() } }
    nonisolated func allowExit() { exitAllowed.withLock { $0 = true } }
    func answer(requestID: String, decision: PermissionDecision) {}
}

private actor OwnershipRunnerGate {
    private var didStart = false, didTerminate = false
    private var startWait: CheckedContinuation<Void, Never>?
    private var terminateWait: CheckedContinuation<Void, Never>?
    func started() { didStart = true; startWait?.resume(); startWait = nil }
    func terminated() { didTerminate = true; terminateWait?.resume(); terminateWait = nil }
    func waitForStart() async {
        guard !didStart else { return }
        await withCheckedContinuation { startWait = $0 }
    }
    func waitForTermination() async {
        guard !didTerminate else { return }
        await withCheckedContinuation { terminateWait = $0 }
    }
}
