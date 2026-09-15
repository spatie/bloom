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
        try await fixture.expectOwnershipRefused()
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
        try await fixture.expectOwnershipRefused()
        fixture.runner.allowExit()
        // Returns as soon as the replacement starts. The limit is long for the reason the
        // fixture's runner exit grace is: CI's executor stalls outlast the default six seconds.
        await waitUntil("daemon deinit releases ownership after cleanup", within: .seconds(600)) {
            do {
                let replacement = try await fixture.start()
                await replacement.shutdown()
                return true
            } catch { return false }
        }
    }
    @Test func shutdownClosesAnAlreadyAcceptedIdleClient() async throws {
        let fixture = try await OwnershipFixture()
        let daemon = try await fixture.start()
        let connection = try UnixSocketConnection.connect(to: daemon.socketPath)
        defer { connection.close() }
        let request = ServerRequest(.hello)
        connection.writeLine(String(decoding: try JSONEncoder().encode(request), as: UTF8.self))
        var lines = connection.lines.makeAsyncIterator()
        let line = try #require(await lines.next())
        #expect(try JSONDecoder().decode(ServerReply.self, from: Data(line.utf8)).id == request.id)
        await daemon.shutdown()
        let ended = Mutex(false)
        let reading = Task {
            for await _ in connection.lines {}
            ended.withLock { $0 = true }
        }
        await waitUntil("stopped daemon closes its idle socket", within: .seconds(2)) { ended.withLock { $0 } }
        connection.close()
        await reading.value
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
    /// The runner exit grace is ten minutes here rather than production's six seconds. These
    /// tests hold the runner alive on purpose until `allowExit()`, and CI's test executor stalls
    /// for thirty seconds and more, which let the real grace expire first: shutdown finished
    /// and released ownership while the runner still counted as alive, and the next start failed.
    /// Only `allowExit()` can end the wait now.
    func start() async throws -> ServerDaemon {
        try await ServerDaemon.start(authentication: { agent, _, _ in .init(agent: agent, state: .unknown) }, directory: directory, installedAgents: { _ in [.claudeCode] }, makeRunner: { [runner] _, _, _ in runner }, runnerExitGrace: .seconds(600))
    }

    /// A start refused because this directory is owned, and for no other reason. Checking only
    /// the error type let a start that failed on something else pass as a refusal.
    func expectOwnershipRefused(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        do {
            let unexpected = try await start()
            Issue.record("Expected the data directory to still be owned", sourceLocation: sourceLocation)
            await unexpected.shutdown()
        } catch let failure as ServerFailure {
            #expect(failure.message == "A Bloom server already owns this data directory.", sourceLocation: sourceLocation)
        }
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
