import Foundation
import Testing
@testable import BloomCore

/// Regressions for the concurrency bugs in the process, shell and runner layers. Deliberately
/// self contained: every helper here is private to this file so it cannot collide with the
/// shared test support.
@Suite("Concurrency safety")
struct ConcurrencySafetyTests {

    // MARK: - StreamingProcess

    @Test("keeps every line a process wrote just before it exited", .timeLimit(.minutes(1)))
    func doesNotTruncateOutputWrittenBeforeExit() async throws {
        // The old implementation closed the streams a fixed 50ms after the child exited, so
        // whatever the readability handler had not delivered by then was dropped on the floor.
        let count = 20_000
        let process = StreamingProcess(
            executable: "/bin/zsh",
            arguments: ["-c", "for i in $(seq 1 \(count)); do print -r -- line-$i; done"]
        )

        var seen = 0
        var last = ""
        for try await line in process.lines where line.hasPrefix("line-") {
            seen += 1
            last = line
        }

        #expect(seen == count)
        #expect(last == "line-\(count)")
        #expect(await process.exitStatus == 0)
    }

    @Test("finishes even when a grandchild keeps the pipe open", .timeLimit(.minutes(1)))
    func finishesWhenAnOrphanHoldsStdout() async throws {
        // `sleep` inherits stdout and outlives the shell, so the pipe never reaches EOF. Waiting
        // for EOF alone would wait forever, which is why the quiet period exists.
        let process = StreamingProcess(
            executable: "/bin/zsh",
            arguments: ["-c", "(sleep 45 &) ; print -r -- done"]
        )

        var lines: [String] = []
        for try await line in process.lines { lines.append(line) }

        #expect(lines.contains("done"))
        _ = await process.exitStatus
        process.kill()
    }

    @Test("a launch failure reaches a consumer that subscribes afterwards", .timeLimit(.minutes(1)))
    func aFailedStartStillFinishesTheStream() async throws {
        // `lines` used to be a `lazy var`, so the continuation was only created on first access.
        // Starting first meant the failure was reported into a continuation that did not exist
        // yet, and the consumer that arrived a moment later waited for a stream nobody owned.
        let process = StreamingProcess(
            executable: "bloom-definitely-not-on-path",
            arguments: []
        )

        #expect(throws: (any Error).self) { try process.start() }

        var failed = false
        do {
            for try await _ in process.lines {}
        } catch {
            failed = true
        }

        #expect(failed)
        #expect(await process.exitStatus == 127)
    }

    // MARK: - Shell

    @Test("a cancelled task does not get a subprocess spawned for it")
    func shellRefusesToSpawnForACancelledTask() async {
        let task = Task { () -> ShellResult in
            // Wait until the cancellation has actually landed, so the test is about the guard
            // rather than about who won a race.
            while !Task.isCancelled { await Task.yield() }
            return try await Shell.run("/bin/echo", ["hi"])
        }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
    }

    // MARK: - AgentRunner

    @Test("a finishing run cannot file the turn that replaced it as done", .timeLimit(.minutes(1)))
    func aStaleRunDoesNotOverwriteTheNextTurn() async throws {
        let store = try Store.inMemory()
        let repo = Repo(name: "repo", path: "/tmp/repo")
        try await store.upsert(repo)
        let workspace = Workspace(
            repoID: repo.id, name: "ws", branch: "b", path: "/tmp/ws", baseBranch: "main"
        )
        try await store.upsert(workspace)
        let session = Session(workspaceID: workspace.id, title: "t")
        try await store.upsert(session)

        let first = ScriptedProcess()
        let second = ScriptedProcess()
        let factory = ProcessFactory(processes: [first, second])

        let runner = AgentRunner(
            workspacePath: "/tmp",
            session: session,
            store: store,
            makeProcess: { _ in factory.next() }
        )

        try await runner.send("one")

        // The first process is done with stdout, so the runner is inside `finish`, waiting on the
        // stderr task. `alive` is already false, which is the signal that it got that far.
        first.finishLines()
        try await waitUntil { await runner.isRunning == false }

        // The user starts the next turn while the previous run is still winding down.
        try await runner.send("two")
        #expect(await runner.currentSession.state == .running)

        // Now let the first run finish. Everything it does from here belongs to a run that is no
        // longer current, so none of it may touch the session.
        first.finishErrors()
        try await Task.sleep(for: .milliseconds(200))

        #expect(await runner.currentSession.state == .running)

        second.finishLines()
        second.finishErrors()
    }
}

// MARK: - Doubles

/// Hands out prepared processes in order, so a test can hold on to each one.
private final class ProcessFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [ScriptedProcess]

    init(processes: [ScriptedProcess]) {
        remaining = processes
    }

    func next() -> any AgentProcessing {
        lock.lock(); defer { lock.unlock() }
        return remaining.isEmpty ? ScriptedProcess() : remaining.removeFirst()
    }
}

/// An `AgentProcessing` whose two streams are closed by the test rather than by a real process.
private final class ScriptedProcess: AgentProcessing, @unchecked Sendable {
    let lines: AsyncThrowingStream<String, Error>
    let errorLines: AsyncStream<String>

    private let linesContinuation: AsyncThrowingStream<String, Error>.Continuation
    private let errorContinuation: AsyncStream<String>.Continuation
    private let state = NSLock()
    private var running = true

    init() {
        (lines, linesContinuation) = AsyncThrowingStream.makeStream(of: String.self, throwing: Error.self)
        (errorLines, errorContinuation) = AsyncStream.makeStream(of: String.self)
    }

    var isRunning: Bool {
        state.lock(); defer { state.unlock() }
        return running
    }

    var exitStatus: Int32 { get async { 0 } }

    func finishLines() {
        state.lock(); running = false; state.unlock()
        linesContinuation.finish()
    }

    func finishErrors() {
        errorContinuation.finish()
    }

    func writeLine(_ text: String) {}
    func closeStdin() {}
    func terminate() { finishLines() }
    func kill() { finishLines() }
}

/// Polls a condition instead of sleeping for a guessed interval.
private func waitUntil(
    _ condition: @Sendable () async -> Bool,
    timeout: Duration = .seconds(5)
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("condition never became true")
}

// MARK: - AgentCatalog

@Suite("Agent catalog caching")
struct AgentCatalogCachingTests {

    @Test("concurrent callers share one detection per agent", .timeLimit(.minutes(1)))
    func concurrentCallersDoNotDetectTwice() async {
        let catalog = AgentCatalog()

        // Reading the cache and writing it back is separated by an await, so two callers landing
        // together used to run every detection twice.
        async let first = catalog.statuses()
        async let second = catalog.statuses()
        async let third = catalog.status(for: .claudeCode)

        let (one, two, single) = await (first, second, third)

        #expect(one == two)
        #expect(one.contains { $0.kind == single.kind && $0.connection == single.connection })
        // One detection per agent, no matter how many callers arrived while it was running.
        #expect(await catalog.detectionCount == AgentKind.allCases.count)
    }

    @Test("a refresh does not file an answer gathered before it", .timeLimit(.minutes(1)))
    func invalidateDiscardsADetectionAlreadyInFlight() async {
        let catalog = AgentCatalog()
        _ = await catalog.statuses()
        await catalog.invalidate()
        let after = await catalog.statuses()
        #expect(after.count == AgentKind.allCases.count)
    }
}
