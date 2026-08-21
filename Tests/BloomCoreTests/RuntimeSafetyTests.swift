import Testing
import Foundation
@testable import BloomCore

// MARK: - Fixtures

/// A workspace and a session in a throwaway database, because messages are foreign keyed all the
/// way up to a repo.
private func makeSession(_ store: Store) async throws -> Session {
    let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r-\(UUID().uuidString)"))
    let workspace = try await store.upsert(Workspace(
        repoID: repo.id, name: "w", branch: "b", path: "/tmp/w", baseBranch: "main"
    ))
    return try await store.upsert(Session(workspaceID: workspace.id, model: "opus"))
}

/// A process that can be made to die slowly, or to refuse to die at all, which is the only way to
/// exercise the window between SIGTERM and SIGKILL.
private final class ScriptedProcess: AgentProcessing, @unchecked Sendable {
    let launch: AgentLaunch
    /// How long the process takes to actually exit after being signalled. `nil` never exits.
    private let shutdown: Duration?
    private let lock = NSLock()
    private var written: [String] = []
    private var running = true
    private var terminated = false
    private var killed = false

    private let stdoutContinuation: AsyncThrowingStream<String, Error>.Continuation
    private let stderrContinuation: AsyncStream<String>.Continuation

    let lines: AsyncThrowingStream<String, Error>
    let errorLines: AsyncStream<String>

    init(launch: AgentLaunch, shutdown: Duration? = .zero) {
        self.launch = launch
        self.shutdown = shutdown

        var out: AsyncThrowingStream<String, Error>.Continuation!
        lines = AsyncThrowingStream(bufferingPolicy: .unbounded) { out = $0 }
        stdoutContinuation = out

        var err: AsyncStream<String>.Continuation!
        errorLines = AsyncStream(bufferingPolicy: .unbounded) { err = $0 }
        stderrContinuation = err
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    var exitStatus: Int32 { get async { 0 } }

    func writeLine(_ text: String) {
        lock.lock(); written.append(text); lock.unlock()
    }

    func closeStdin() {}

    func terminate() {
        lock.lock(); terminated = true; lock.unlock()
        guard let shutdown else { return }
        if shutdown == .zero {
            endOutput()
        } else {
            Task { [self] in
                try? await Task.sleep(for: shutdown)
                endOutput()
            }
        }
    }

    func kill() {
        lock.lock(); killed = true; lock.unlock()
        // A `nil` shutdown is a process nothing can reach: uninterruptible sleep in a syscall,
        // which SIGKILL does not cut short either.
        guard shutdown != nil else { return }
        endOutput()
    }

    // MARK: Test controls

    var stdin: [String] {
        lock.lock(); defer { lock.unlock() }
        return written
    }

    var wasTerminated: Bool {
        lock.lock(); defer { lock.unlock() }
        return terminated
    }

    var wasKilled: Bool {
        lock.lock(); defer { lock.unlock() }
        return killed
    }

    func emit(_ line: String) {
        stdoutContinuation.yield(line)
    }

    func endOutput() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        lock.unlock()
        stdoutContinuation.finish()
        stderrContinuation.finish()
    }
}

private final class ProcessRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [ScriptedProcess] = []
    private let shutdown: Duration?

    init(shutdown: Duration? = .zero) {
        self.shutdown = shutdown
    }

    var factory: @Sendable (AgentLaunch) -> any AgentProcessing {
        { launch in
            let process = ScriptedProcess(launch: launch, shutdown: self.shutdown)
            self.lock.lock(); self.made.append(process); self.lock.unlock()
            return process
        }
    }

    var all: [ScriptedProcess] {
        lock.lock(); defer { lock.unlock() }
        return made
    }
}

private actor Counter {
    private(set) var count = 0
    func bump() { count += 1 }
}

/// Read a fixed number of events off a stream, so a test never hangs on one that stalled.
private func take(_ count: Int, from stream: AsyncStream<AgentEvent>) async -> [AgentEvent] {
    var events: [AgentEvent] = []
    guard count > 0 else { return events }
    for await event in stream {
        events.append(event)
        if events.count == count { break }
    }
    return events
}

private let assistantLine = #"""
{"type":"assistant","uuid":"u1","session_id":"s1","message":{"id":"m1","role":"assistant",\
"model":"claude-opus-5","content":[{"type":"text","text":"hello"}]}}
"""#.replacingOccurrences(of: "\\\n", with: "")

// MARK: - Event fan out

@Suite("AgentRunner event fan out", .tags(.agentProtocol), .scratchDirectory, .timeLimit(.minutes(1)))
struct AgentRunnerEventFanOutTests {
    @Test("every subscriber receives every event, in order")
    func broadcastsToEverySubscriber() async throws {
        let store = try makeTestStore("runtime")
        let session = try await makeSession(store)
        let runner = AgentRunner(workspacePath: "/tmp/w", session: session, store: store)

        // Both streams are taken before anything is yielded, which is what registers them.
        let first = runner.events
        let second = runner.events

        // Six deliveries and not one more: three events reaching two subscribers each. A
        // confirmation says that out loud, where counting array lengths afterwards cannot rule
        // out a fourth event arriving late.
        await confirmation("an event reached a subscriber", expectedCount: 6) { delivered in
            let a = Task { () -> [AgentEvent] in
                let events = await take(3, from: first)
                for _ in events { delivered() }
                return events
            }
            let b = Task { () -> [AgentEvent] in
                let events = await take(3, from: second)
                for _ in events { delivered() }
                return events
            }

            await runner.ingest(.status("one"))
            await runner.ingest(.status("two"))
            await runner.ingest(.status("three"))

            #expect(await a.value.map(statusLabel) == ["one", "two", "three"])
            #expect(await b.value.map(statusLabel) == ["one", "two", "three"])
        }
    }

    @Test("cancelling one subscriber leaves the others working")
    func oneCancellationDoesNotKillTheRest() async throws {
        let store = try makeTestStore("runtime")
        let session = try await makeSession(store)
        let runner = AgentRunner(workspacePath: "/tmp/w", session: session, store: store)

        let doomed = runner.events
        let survivor = runner.events

        let seen = Counter()
        let doomedTask = Task {
            for await _ in doomed { await seen.bump() }
        }

        await runner.ingest(.status("one"))
        await waitUntil("the doomed subscriber saw the first event") { await seen.count == 1 }
        doomedTask.cancel()
        _ = await doomedTask.value

        await runner.ingest(.status("two"))
        await runner.ingest(.status("three"))

        let received = await take(3, from: survivor)
        #expect(received.map(statusLabel) == ["one", "two", "three"])
        #expect(await seen.count == 1)
    }

    @Test("a second turn after Stop still delivers events")
    func secondTurnAfterStopStillDelivers() async throws {
        let store = try makeTestStore("runtime")
        let session = try await makeSession(store)
        let recorder = ProcessRecorder()
        let runner = AgentRunner(
            workspacePath: "/tmp/w", session: session, store: store, makeProcess: recorder.factory
        )

        // Turn one, watched the way the UI watches it.
        let firstStream = runner.events
        let firstTurn = Counter()
        let pump = Task {
            for await _ in firstStream { await firstTurn.bump() }
        }

        try await runner.send("one")
        recorder.all[0].emit(assistantLine)
        await waitUntil("the first turn delivered an event") { await firstTurn.count == 1 }

        // Stop: the view cancels the task iterating the stream, which used to finish the only
        // stream the runner had.
        runner.cancelNow()
        pump.cancel()
        _ = await pump.value
        await waitUntil("the runner stopped") { await runner.isRunning == false }

        // Turn two, with a fresh subscriber, exactly as the UI would do it.
        let secondStream = runner.events
        try await runner.send("two")
        #expect(recorder.all.count == 2)
        recorder.all[1].emit(assistantLine)

        let received = await take(1, from: secondStream)
        #expect(received.count == 1)

        // Two user turns Bloom wrote itself plus the two assistant lines. Persisting happens
        // just off the delivery path, so wait for the count rather than reading it once and
        // settling for "more than nothing".
        await waitUntil("both turns were persisted") {
            (try? await store.messageCount(sessionID: session.id)) == 4
        }
        let stored = try await store.messages(sessionID: session.id)
        #expect(stored.count == 4)
        #expect(stored.map(\.kind) == [.user, .assistantText, .user, .assistantText])
        #expect(stored.map(\.seq) == [0, 1, 2, 3])
    }
}

/// The text of a turn as it went over stdin. Read back rather than compared byte for byte,
/// because `JSONEncoder` does not promise a key order.
private func turnText(_ line: String) -> String {
    JSONValue.parse(line)?["message"]?["content"]?[0]?["text"]?.stringValue ?? ""
}

private func statusLabel(_ event: AgentEvent) -> String {
    if case .status(let label) = event { return label }
    return ""
}

// MARK: - Hostile JSON

@Suite("JSONValue hostile input", .tags(.agentProtocol, .security))
struct JSONValueHostileInputTests {
    @Test("a number Int cannot hold reads as nil instead of trapping")
    func hugeNumbersDoNotTrap() throws {
        let line = #"{"type":"system","subtype":"thinking_tokens","estimated_tokens":1e100}"#
        #expect(AgentEvent.decode(line: line) != nil)
        if case .thinkingTokens(let tokens) = AgentEvent.decode(line: line) {
            #expect(tokens == 0)
        } else {
            Issue.record("expected a thinking token event")
        }

        for text in ["1e100", "-1e100", "1e309", "-1e309", "9223372036854775808"] {
            let json = JSONValue.parse("{\"n\":\(text)}")
            #expect(json?["n"]?.intValue == nil, "\(text) should not convert to Int")
            _ = json?["n"]?.doubleValue
            _ = json?.prettyPrinted
        }

        // Underflow is not overflow: this one really is zero.
        #expect(JSONValue.parse(#"{"n":1e-400}"#)?["n"]?.intValue == 0)
    }

    @Test("an integer past 2^53 survives the round trip exactly")
    func keepsBigIntegersExact() throws {
        let json = try #require(JSONValue.parse(#"{"n":9007199254740993,"m":-9007199254740993}"#))
        #expect(json["n"]?.intValue == 9_007_199_254_740_993)
        #expect(json["m"]?.intValue == -9_007_199_254_740_993)
        #expect(json.prettyPrinted.contains("9007199254740993"))
        #expect(JSONValue.parse(json.prettyPrinted) == json)

        let extremes = try #require(JSONValue.parse("{\"max\":\(Int.max),\"min\":\(Int.min)}"))
        #expect(extremes["max"]?.intValue == Int.max)
        #expect(extremes["min"]?.intValue == Int.min)
    }

    @Test("still reads the small numbers the protocol is actually made of")
    func readsOrdinaryNumbers() throws {
        let json = try #require(JSONValue.parse(#"{"count":3,"ratio":0.5,"zero":0,"cost":0.119112}"#))
        #expect(json["count"]?.intValue == 3)
        #expect(json["count"]?.doubleValue == 3)
        #expect(json["ratio"]?.doubleValue == 0.5)
        #expect(json["ratio"]?.intValue == 0)
        #expect(json["zero"]?.intValue == 0)
        #expect(json["cost"]?.doubleValue == 0.119112)
        #expect(json["count"]?.stringValue == nil)
    }

    @Test("NaN and infinity convert to nothing rather than trapping")
    func handlesNonFiniteDoubles() {
        for value in [Double.nan, .infinity, -.infinity, .signalingNaN] {
            #expect(JSONValue.number(value).intValue == nil)
            #expect(JSONValue.number(value).doubleValue?.isFinite == false)
            // Encoding a non-finite Double is not valid JSON, so this is empty, never a crash.
            #expect(JSONValue.number(value).prettyPrinted == "")
        }
    }

    @Test("deeply nested JSON is refused rather than blowing the stack")
    func handlesDeepNesting() {
        for depth in [8, 64, 512, 5_000, 100_000] {
            let arrays = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
            _ = JSONValue.parse(arrays)
            _ = AgentEvent.decode(line: arrays)

            let objects = String(repeating: #"{"a":"#, count: depth) + "1"
                + String(repeating: "}", count: depth)
            _ = JSONValue.parse(objects)
            _ = AgentEvent.decode(line: objects)
        }
    }

    @Test("no line of any shape can trap the decoder")
    func fuzzesTheDecoder() {
        var generator = SeededGenerator(seed: 0x5EED_1234)
        let numbers = [
            "1e100", "-1e100", "1e309", "1e-400", "9007199254740993", "-9007199254740993",
            "9223372036854775807", "9223372036854775808", "-9223372036854775809",
            "0", "-0", "0.0", "3.5", "-1", String(repeating: "9", count: 400), "1E+2", "2e-2",
        ]
        let fragments = ["null", "true", "false", "\"\"", "\"x\"", "[]", "{}", "{\"a\":", "}", "]", ","]
        let keys = ["type", "subtype", "estimated_tokens", "usage", "message", "content", "exit_code"]

        for _ in 0..<3_000 {
            var line = ""
            for _ in 0..<Int.random(in: 1...8, using: &generator) {
                switch Int.random(in: 0...3, using: &generator) {
                case 0: line += numbers.randomElement(using: &generator)!
                case 1: line += fragments.randomElement(using: &generator)!
                case 2: line += "{\"\(keys.randomElement(using: &generator)!)\":"
                    + numbers.randomElement(using: &generator)! + "}"
                default: line += "\"\(keys.randomElement(using: &generator)!)\""
                }
            }

            if let event = AgentEvent.decode(line: line) {
                // Touch everything a renderer would touch. None of it may trap either.
                _ = event.raw
                _ = event.kind
                _ = event.uuid
                _ = event.sessionID
                _ = event.refID
                _ = JSONValue.parse(event.raw)?.prettyPrinted
            }

            let usage = AgentUsage.decode(JSONValue.parse(line))
            _ = usage.contextFraction
        }
    }
}

/// Deterministic randomness, so a failing fuzz run reproduces.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Persistence failures

@Suite("AgentRunner persistence failures", .tags(.persistence), .scratchDirectory, .timeLimit(.minutes(1)))
struct AgentRunnerPersistenceFailureTests {
    @Test("surfaces a failed write instead of pretending the row landed")
    func surfacesFailedAppend() async throws {
        let store = try makeTestStore("runtime")
        // A session that was never inserted: the foreign key on messages refuses every row.
        let session = Session(workspaceID: WorkspaceID("no-such-workspace"))
        let runner = AgentRunner(workspacePath: "/tmp/w", session: session, store: store)

        let events = runner.events
        await runner.ingest(.assistantText(AgentTextBlock(text: "hi", raw: Data("{}".utf8))))

        let received = await take(2, from: events)
        #expect(received.count == 2)
        guard case .error(let failure) = received[0] else {
            Issue.record("the failed write should reach the stream as an error")
            return
        }
        #expect(failure.message.contains("Could not store"))
        #expect(JSONValue.parse(failure.raw)?["subtype"]?.stringValue == "storage")
        if case .assistantText = received[1] {} else {
            Issue.record("the event itself should still be delivered")
        }

        #expect(await runner.lastPersistenceFailure != nil)
        #expect(await runner.persistenceFailureCount == 1)
        #expect(try await store.messageCount(sessionID: session.id) == 0)
    }

    @Test("a failed write leaves the sequence where it was")
    func failedWriteDoesNotBurnASequenceNumber() async throws {
        let store = try makeTestStore("runtime")
        let session = try await makeSession(store)
        let broken = Session(id: session.id, workspaceID: session.workspaceID)
        let runner = AgentRunner(workspacePath: "/tmp/w", session: broken, store: store)

        // A payload no row can hold: a kind is fine, but the session id must exist. Delete the
        // session out from under the runner, write, then put it back.
        try await store.deleteSession(id: session.id)
        await runner.ingest(.assistantText(AgentTextBlock(text: "lost", raw: Data("{}".utf8))))
        #expect(await runner.persistenceFailureCount == 1)

        _ = try await store.upsert(session)
        await runner.ingest(.assistantText(AgentTextBlock(text: "kept", raw: Data("{}".utf8))))

        let stored = try await store.messages(sessionID: session.id)
        #expect(stored.map(\.seq) == [0])
        #expect(await runner.persistenceFailureCount == 1)
    }
}

// MARK: - Sequence allocation

@Suite("Store sequence allocation", .tags(.persistence), .scratchDirectory)
struct StoreSequenceAllocationTests {
    @Test("allocates every sequence number exactly once under concurrency")
    func allocatesConcurrently() async throws {
        let store = try makeTestStore("runtime")
        let session = try await makeSession(store)

        let reserved = await withTaskGroup(of: Int?.self, returning: [Int].self) { group in
            for index in 0..<50 {
                group.addTask {
                    try? await store.appendNext(
                        sessionID: session.id, kind: .system, payload: Data("\(index)".utf8)
                    ).seq
                }
            }
            var seqs: [Int] = []
            for await seq in group { if let seq { seqs.append(seq) } }
            return seqs
        }

        #expect(reserved.sorted() == Array(0..<50))
        let stored = try await store.messages(sessionID: session.id)
        #expect(stored.map(\.seq) == Array(0..<50))
    }

    @Test("refuses a second row claiming a position that is taken")
    func refusesDuplicateSeq() async throws {
        let store = try makeTestStore("runtime")
        let session = try await makeSession(store)
        try await store.append(Message(sessionID: session.id, seq: 0, kind: .system, payload: Data()))

        await #expect(throws: SQLiteError.self) {
            try await store.append(Message(
                sessionID: session.id, seq: 0, kind: .system, payload: Data()
            ))
        }
        #expect(try await store.messageCount(sessionID: session.id) == 1)
    }

    @Test("constrains a database that already holds duplicate positions")
    func migratesADatabaseWithDuplicates() async throws {
        let path = TestScratch.unique("bloom-migrate") + ".sqlite"
        let session: Session
        do {
            let store = try Store(path: path)
            session = try await makeSession(store)
        }

        // Rewind to the schema before the constraint existed and plant what it was added to catch.
        let db = try SQLiteDatabase(path: path)
        try db.execute("DROP INDEX IF EXISTS messages_session_seq;")
        db.userVersion = 1
        for (seq, body) in [(0, "a"), (1, "b"), (1, "c"), (2, "d")] {
            try db.run(
                """
                INSERT INTO messages (session_id, seq, kind, payload, created_at)
                VALUES (?, ?, 'system', ?, ?)
                """,
                [
                    .text(session.id), .int(Int64(seq)), .blob(Data(body.utf8)),
                    .double(Date().timeIntervalSince1970),
                ]
            )
        }

        let reopened = try Store(path: path)
        let messages = try await reopened.messages(sessionID: session.id)
        #expect(messages.count == 4)
        #expect(Set(messages.map(\.seq)).count == 4)
        #expect(Set(messages.map { String(decoding: $0.payload, as: UTF8.self) }) == ["a", "b", "c", "d"])

        // And the constraint is live from here on.
        await #expect(throws: SQLiteError.self) {
            try await reopened.append(Message(
                sessionID: session.id, seq: 0, kind: .system, payload: Data()
            ))
        }
    }
}

// MARK: - Cancellation races

@Suite("AgentRunner cancellation races", .tags(.subprocess), .scratchDirectory, .timeLimit(.minutes(1)))
struct AgentRunnerCancellationRaceTests {
    @Test("a cancel meant for the previous run leaves the new one alone")
    func staleCancelIsDropped() async throws {
        let store = try makeTestStore("runtime")
        let session = try await makeSession(store)
        let recorder = ProcessRecorder()
        let runner = AgentRunner(
            workspacePath: "/tmp/w", session: session, store: store, makeProcess: recorder.factory
        )

        try await runner.send("one")
        await runner.cancel()
        await waitUntil("the runner stopped") { await runner.isRunning == false }

        try await runner.send("two")
        #expect(recorder.all.count == 2)

        // The cancel the user asked for during run one, arriving late.
        await runner.cancel(generation: 1)

        #expect(recorder.all[1].wasTerminated == false)
        #expect(await runner.currentSession.state == .running)
        #expect(await runner.isRunning)
        recorder.all[1].endOutput()
    }

    @Test("a turn sent while the previous process is still dying waits for it")
    func sendWaitsForTheDyingProcess() async throws {
        let store = try makeTestStore("runtime")
        let session = try await makeSession(store)
        let recorder = ProcessRecorder(shutdown: .milliseconds(300))
        let runner = AgentRunner(
            workspacePath: "/tmp/w", session: session, store: store, makeProcess: recorder.factory
        )

        try await runner.send("one")
        runner.cancelNow()
        #expect(recorder.all[0].wasTerminated)
        #expect(recorder.all[0].isRunning)

        try await runner.send("two")

        #expect(recorder.all.count == 2)
        #expect(recorder.all[0].stdin.map(turnText) == ["one"])
        #expect(recorder.all[1].stdin.map(turnText) == ["two"])
        recorder.all[1].endOutput()
    }

    @Test("a turn gives up with a clear error when the previous process will not die")
    func sendFailsOnAProcessThatNeverExits() async throws {
        let store = try makeTestStore("runtime")
        let session = try await makeSession(store)
        let recorder = ProcessRecorder(shutdown: nil)
        let runner = AgentRunner(
            workspacePath: "/tmp/w", session: session, store: store, makeProcess: recorder.factory
        )

        try await runner.send("one")
        runner.cancelNow()

        await #expect(throws: AgentRunnerError.previousRunStillExiting) {
            try await runner.send("two")
        }
        #expect(recorder.all.count == 1)
        #expect(recorder.all[0].stdin.count == 1)
        recorder.all[0].endOutput()
    }
}

// MARK: - Process trees

@Suite("StreamingProcess signals", .tags(.subprocess), .timeLimit(.minutes(1)))
struct StreamingProcessSignalTests {
    @Test("terminate kills the grandchildren too")
    func killsTheWholeGroup() async throws {
        let process = StreamingProcess(
            executable: "sh",
            arguments: ["-c", "sleep 45 & echo $!; sleep 45"],
            mergeStderr: false
        )

        var iterator = process.lines.makeAsyncIterator()
        let line = try await iterator.next()
        let printed = try #require(line).trimmingCharacters(in: .whitespaces)
        let grandchild = try #require(pid_t(printed))
        #expect(kill(grandchild, 0) == 0)

        process.terminate()

        var alive = true
        for _ in 0..<200 {
            if kill(grandchild, 0) != 0 { alive = false; break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        #expect(alive == false, "the grandchild outlived the process group")
    }

    @Test("signalling a process that already exited is harmless")
    func signallingAfterExitIsANoOp() async throws {
        let process = StreamingProcess(executable: "sh", arguments: ["-c", "exit 0"], mergeStderr: false)
        for try await _ in process.lines {}
        #expect(await process.exitStatus == 0)

        // Nothing here may reach our own process group, so the test surviving is the assertion.
        process.terminate()
        process.kill()
        #expect(process.isRunning == false)
    }
}
