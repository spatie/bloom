import Testing
import Foundation
@testable import BloomCore

// MARK: - Fixtures

/// A workspace and a session in a throwaway database, because messages are foreign keyed all the
/// way up to a repo.
private func makeSession(_ store: Store, permissionMode: PermissionMode = .acceptEdits) async throws -> Session {
    let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r-\(UUID().uuidString)"))
    let workspace = try await store.upsert(Workspace(
        repoID: repo.id, name: "w", branch: "b", path: "/tmp/w", baseBranch: "main"
    ))
    return try await store.upsert(Session(
        workspaceID: workspace.id, model: "opus", permissionMode: permissionMode
    ))
}

/// A process that never was. Records what would have been written to stdin and replays canned
/// lines, so the runner can be exercised without the real `claude` binary.
private final class FakeProcess: AgentProcessing, @unchecked Sendable {
    let launch: AgentLaunch
    private let lock = NSLock()
    private var written: [String] = []
    private var terminated = false
    private var killed = false
    private var running = true
    private let status: Int32

    private let stdoutContinuation: AsyncThrowingStream<String, Error>.Continuation
    private let stderrContinuation: AsyncStream<String>.Continuation

    let lines: AsyncThrowingStream<String, Error>
    let errorLines: AsyncStream<String>

    init(launch: AgentLaunch, status: Int32 = 0) {
        self.launch = launch
        self.status = status

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

    var exitStatus: Int32 {
        get async { status }
    }

    func writeLine(_ text: String) {
        lock.lock(); written.append(text); lock.unlock()
    }

    func closeStdin() {}

    func terminate() {
        lock.lock(); terminated = true; running = false; lock.unlock()
        stdoutContinuation.finish()
        stderrContinuation.finish()
    }

    func kill() {
        lock.lock(); killed = true; running = false; lock.unlock()
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

    func emit(_ line: String) {
        stdoutContinuation.yield(line)
    }

    func emitError(_ line: String) {
        stderrContinuation.yield(line)
    }

    func endOutput() {
        lock.lock(); running = false; lock.unlock()
        stdoutContinuation.finish()
        stderrContinuation.finish()
    }
}

/// Hands out the fake the test is holding, and records the launch it was asked for.
private final class ProcessRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [FakeProcess] = []
    private let status: Int32

    init(status: Int32 = 0) {
        self.status = status
    }

    var factory: @Sendable (AgentLaunch) -> any AgentProcessing {
        { launch in
            let process = FakeProcess(launch: launch, status: self.status)
            self.append(process)
            return process
        }
    }

    private func append(_ process: FakeProcess) {
        lock.lock(); made.append(process); lock.unlock()
    }

    var all: [FakeProcess] {
        lock.lock(); defer { lock.unlock() }
        return made
    }

    var last: FakeProcess? { all.last }
}

// MARK: - Tests

@Suite("AgentRunner argv", .tags(.agentProtocol), .scratchDirectory)
struct AgentRunnerArgvTests {
    @Test("builds the invocation PROTOCOL.md specifies")
    func buildsArgv() {
        let session = Session(workspaceID: "w", model: "opus", permissionMode: .acceptEdits)
        #expect(AgentRunner.argv(session: session, resume: nil) == [
            "-p",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--permission-mode", "acceptEdits",
            "--model", "opus",
        ])
    }

    @Test("appends resume when there is an agent session to resume")
    func appendsResume() throws {
        let session = Session(workspaceID: "w", model: "sonnet")
        let argv = AgentRunner.argv(session: session, resume: "f93932c9-cf0b-40d8-881c-ac75db3f8740")
        #expect(argv.suffix(2) == ["--resume", "f93932c9-cf0b-40d8-881c-ac75db3f8740"])
        let model = try #require(argv.firstIndex(of: "--model"))
        #expect(argv[model + 1] == "sonnet")
    }

    @Test("leaves resume off for an empty or missing id")
    func skipsEmptyResume() {
        let session = Session(workspaceID: "w")
        #expect(AgentRunner.argv(session: session, resume: "").contains("--resume") == false)
        #expect(AgentRunner.argv(session: session, resume: nil).contains("--resume") == false)
    }

    @Test("maps every permission mode to a value the CLI accepts", arguments: [
        (PermissionMode.auto, "auto"),
        (.acceptEdits, "acceptEdits"),
        (.bypassPermissions, "bypassPermissions"),
        (.plan, "plan"),
    ])
    func mapsPermissionModes(mode: PermissionMode, cliValue: String) throws {
        let session = Session(workspaceID: "w", permissionMode: mode)
        let argv = AgentRunner.argv(session: session, resume: nil)
        let index = try #require(argv.firstIndex(of: "--permission-mode"))
        #expect(argv[index + 1] == cliValue)
        #expect(mode.cliValue == cliValue)
    }

    @Test("covers every permission mode the app can be in")
    func coversEveryPermissionMode() {
        // A new case added to the enum has to be added to the table above too, or the CLI is
        // handed a value nothing checked.
        #expect(PermissionMode.allCases.count == 4)
    }

    @Test("launches in the worktree, resuming once the agent session is known")
    func buildsLaunch() async throws {
        let store = try makeTestStore("agent")
        var session = try await makeSession(store)
        session.agentSessionID = "resume-me"
        let runner = AgentRunner(workspacePath: "/tmp/worktree", session: session, store: store)

        let launch = await runner.launch()
        #expect(launch.executable == "claude")
        #expect(launch.cwd == "/tmp/worktree")
        #expect(launch.arguments.suffix(2) == ["--resume", "resume-me"])
        #expect(launch.environment["PATH"]?.contains("/usr/bin") == true)
    }

    @Test("encodes a user turn as one line of NDJSON")
    func encodesTurn() throws {
        let line = try AgentRunner.encodeTurn("write /tmp/out.txt \"now\"")
        #expect(line.contains("\n") == false)

        let json = try #require(JSONValue.parse(line))
        #expect(json["type"]?.stringValue == "user")
        #expect(json["message"]?["role"]?.stringValue == "user")
        #expect(json["message"]?["content"]?[0]?["type"]?.stringValue == "text")
        #expect(json["message"]?["content"]?[0]?["text"]?.stringValue == "write /tmp/out.txt \"now\"")
    }
}

@Suite("AgentRunner persistence", .tags(.agentProtocol, .persistence), .scratchDirectory)
struct AgentRunnerPersistenceTests {
    @Test("stores every transcript row in order with the raw JSON")
    func storesTranscript() async throws {
        let store = try makeTestStore("agent")
        let session = try await makeSession(store)
        let runner = AgentRunner(workspacePath: "/tmp/w", session: session, store: store)

        let lines = try fixtureSessionLines()
        for event in lines.compactMap({ AgentEvent.decode(line: $0) }) {
            await runner.ingest(event)
        }

        let messages = try await store.messages(sessionID: session.id)
        #expect(messages.count == 25)
        #expect(messages.map(\.seq) == Array(0..<25))
        #expect(messages.filter { $0.kind == .toolUse }.count == 2)
        #expect(messages.filter { $0.kind == .toolResult }.count == 2)
        #expect(messages.filter { $0.kind == .assistantText }.count == 2)
        #expect(messages.filter { $0.kind == .result }.count == 1)
        #expect(messages.filter { $0.kind == .notice }.count == 1)

        let stored = try #require(messages.first { $0.kind == .toolUse })
        #expect(JSONValue.parse(stored.payload)?["type"]?.stringValue == "assistant")
    }

    @Test("files tool use rows under their tool_use id so results can pair up")
    func filesRefIDs() async throws {
        let store = try makeTestStore("agent")
        let session = try await makeSession(store)
        let runner = AgentRunner(workspacePath: "/tmp/w", session: session, store: store)

        for event in try fixtureSessionLines().compactMap({ AgentEvent.decode(line: $0) }) {
            await runner.ingest(event)
        }

        let paired = try await store.message(sessionID: session.id, refID: "toolu_01PpKZErcdXrhaSWzLBno4Ra")
        #expect(paired != nil)
        // The result row is written after the call row, so the newest match is the result.
        #expect(paired?.kind == .toolResult)

        let all = try await store.messages(sessionID: session.id)
        let refs = all.filter { $0.refID == "toolu_01TWLhjSjYuicXQJSDpTGa2V" }
        #expect(refs.map(\.kind) == [.toolUse, .toolResult])
    }

    @Test("drops stream deltas from the transcript unless asked to keep them")
    func dropsStreamDeltas() async throws {
        let store = try makeTestStore("agent")
        let session = try await makeSession(store)
        let runner = AgentRunner(workspacePath: "/tmp/w", session: session, store: store)

        await runner.ingest(.streamDelta(.text("hel")))
        await runner.ingest(.streamDelta(.text("lo")))
        #expect(try await store.messageCount(sessionID: session.id) == 0)

        await runner.setPersistsStreamDeltas(true)
        await runner.ingest(.streamDelta(.blockFinished))
        #expect(try await store.messageCount(sessionID: session.id) == 1)
    }

    @Test("persists the agent session id the moment init arrives")
    func persistsAgentSessionID() async throws {
        let store = try makeTestStore("agent")
        let session = try await makeSession(store)
        let runner = AgentRunner(workspacePath: "/tmp/w", session: session, store: store)

        let line = try #require(try fixtureSessionLines().first { $0.contains("\"subtype\":\"init\"") })
        await runner.ingest(try #require(AgentEvent.decode(line: line)))

        let reloaded = try await store.session(id: session.id)
        #expect(reloaded?.agentSessionID == "f93932c9-cf0b-40d8-881c-ac75db3f8740")
        #expect(await runner.launch().arguments.suffix(2) == ["--resume", "f93932c9-cf0b-40d8-881c-ac75db3f8740"])
    }

    @Test("rolls the result usage into the session")
    func updatesSessionOnResult() async throws {
        let store = try makeTestStore("agent")
        let session = try await makeSession(store)
        let runner = AgentRunner(workspacePath: "/tmp/w", session: session, store: store)

        let resultLine = try #require(try fixtureSessionLines().last { $0.contains("\"type\":\"result\"") })
        await runner.ingest(try #require(AgentEvent.decode(line: resultLine)))

        let reloaded = try #require(try await store.session(id: session.id))
        #expect(reloaded.inputTokens == 6)
        #expect(reloaded.outputTokens == 360)
        #expect(abs(reloaded.costUSD - 0.119112) < 0.000001)
        #expect(reloaded.contextTokens == 6 + 100_420 + 13_928)
        #expect(reloaded.state == .idle)

        // A second turn accumulates rather than replacing.
        await runner.ingest(try #require(AgentEvent.decode(line: resultLine)))
        #expect(try await store.session(id: session.id)?.outputTokens == 720)

        let stored = try await store.messages(sessionID: session.id)
        #expect(stored.map(\.durationMS) == [7880, 7880])
    }

    @Test("marks the session failed when the result says so")
    func failsOnErrorResult() async throws {
        let store = try makeTestStore("agent")
        let session = try await makeSession(store)
        let runner = AgentRunner(workspacePath: "/tmp/w", session: session, store: store)

        let line = #"""
        {"type":"result","subtype":"error_max_turns","is_error":true,"duration_ms":10,\
        "num_turns":9,"session_id":"s1","total_cost_usd":0.5,"result":"","uuid":"u"}
        """#.replacingOccurrences(of: "\\\n", with: "")
        await runner.ingest(try #require(AgentEvent.decode(line: line)))

        #expect(try await store.session(id: session.id)?.state == .failed)
    }

    @Test("continues the sequence of an already stored transcript")
    func continuesSeq() async throws {
        let store = try makeTestStore("agent")
        let session = try await makeSession(store)
        try await store.append(Message(
            sessionID: session.id, seq: 0, kind: .user, payload: Data("{}".utf8)
        ))
        try await store.append(Message(
            sessionID: session.id, seq: 1, kind: .assistantText, payload: Data("{}".utf8)
        ))

        let runner = AgentRunner(workspacePath: "/tmp/w", session: session, store: store)
        await runner.ingest(.error(AgentError(message: "boom", raw: Data("{}".utf8))))
        await runner.ingest(.error(AgentError(message: "boom", raw: Data("{}".utf8))))

        let messages = try await store.messages(sessionID: session.id)
        #expect(messages.map(\.seq) == [0, 1, 2, 3])
        #expect(messages.suffix(2).allSatisfy { $0.kind == .error })
    }
}

@Suite("AgentRunner process", .tags(.agentProtocol, .subprocess), .scratchDirectory, .timeLimit(.minutes(1)))
struct AgentRunnerProcessTests {
    @Test("sends a turn, replays the stream, and lands idle")
    func runsATurn() async throws {
        let store = try makeTestStore("agent")
        let session = try await makeSession(store)
        let recorder = ProcessRecorder()
        let runner = AgentRunner(
            workspacePath: "/tmp/w", session: session, store: store, makeProcess: recorder.factory
        )

        let collector = Task {
            var events: [AgentEvent] = []
            for await event in runner.events {
                events.append(event)
                if case .result = event { break }
            }
            return events
        }

        try await runner.send("do the thing")
        #expect(await runner.isRunning)

        let process = try #require(recorder.last)
        #expect(process.launch.arguments.contains("--include-partial-messages"))
        #expect(process.stdin.count == 1)
        #expect(JSONValue.parse(process.stdin[0])?["message"]?["content"]?[0]?["text"]?.stringValue
            == "do the thing")

        for line in try fixtureSessionLines() { process.emit(line) }
        let received = await collector.value
        process.endOutput()

        #expect(received.count == 55)
        await waitUntil("the runner stopped") { await runner.isRunning == false }

        let reloaded = try #require(try await store.session(id: session.id))
        #expect(reloaded.agentSessionID == "f93932c9-cf0b-40d8-881c-ac75db3f8740")
        #expect(reloaded.state == .idle)
        #expect(reloaded.outputTokens == 360)

        // 25 event rows plus the user turn Bloom wrote itself.
        #expect(try await store.messageCount(sessionID: session.id) == 26)
        let first = try await store.messages(sessionID: session.id)[0]
        #expect(first.kind == .user)
    }

    @Test("records an error row and fails the session on a non-zero exit with no result")
    func failsWithoutResult() async throws {
        let store = try makeTestStore("agent")
        let session = try await makeSession(store)
        let recorder = ProcessRecorder(status: 2)
        let runner = AgentRunner(
            workspacePath: "/tmp/w", session: session, store: store, makeProcess: recorder.factory
        )

        try await runner.send("hello")
        let process = try #require(recorder.last)
        process.emitError("error: not logged in")
        process.emit(#"{"type":"system","subtype":"status","status":"requesting","session_id":"s"}"#)
        process.endOutput()

        await waitUntil("the session was marked failed") { (try? await store.session(id: session.id)?.state) == .failed }

        let reloaded = try #require(try await store.session(id: session.id))
        #expect(reloaded.state == .failed)

        let errors = try await store.messages(sessionID: session.id).filter { $0.kind == .error }
        #expect(errors.count == 1)
        let payload = try #require(JSONValue.parse(errors[0].payload))
        #expect(payload["status"]?.intValue == 2)
        #expect(payload["stderr"]?.stringValue == "error: not logged in")
    }

    @Test("cancelling terminates the process and marks the session cancelled")
    func cancels() async throws {
        let store = try makeTestStore("agent")
        let session = try await makeSession(store)
        let recorder = ProcessRecorder()
        let runner = AgentRunner(
            workspacePath: "/tmp/w", session: session, store: store, makeProcess: recorder.factory
        )

        try await runner.send("long job")
        let process = try #require(recorder.last)

        await runner.cancel()
        #expect(process.wasTerminated)
        await waitUntil("the session was marked cancelled") { (try? await store.session(id: session.id)?.state) == .cancelled }
        #expect(try await store.session(id: session.id)?.state == .cancelled)
        #expect(await runner.isRunning == false)
    }

    @Test("cancelNow signals without awaiting the actor")
    func cancelsFromSyncCode() async throws {
        let store = try makeTestStore("agent")
        let session = try await makeSession(store)
        let recorder = ProcessRecorder()
        let runner = AgentRunner(
            workspacePath: "/tmp/w", session: session, store: store, makeProcess: recorder.factory
        )

        try await runner.send("long job")
        let process = try #require(recorder.last)

        runner.cancelNow()
        #expect(process.wasTerminated)
        await waitUntil("the session was marked cancelled") { (try? await store.session(id: session.id)?.state) == .cancelled }
        #expect(try await store.session(id: session.id)?.state == .cancelled)
    }

    @Test("a second turn reuses the running process")
    func reusesProcess() async throws {
        let store = try makeTestStore("agent")
        let session = try await makeSession(store)
        let recorder = ProcessRecorder()
        let runner = AgentRunner(
            workspacePath: "/tmp/w", session: session, store: store, makeProcess: recorder.factory
        )

        try await runner.send("first")
        try await runner.send("second")

        #expect(recorder.all.count == 1)
        #expect(recorder.last?.stdin.count == 2)
        recorder.last?.endOutput()
    }
}

// MARK: - Fixture access

private func fixtureSessionLines() throws -> [String] {
    try bloomFixtureLines("session-basic.jsonl")
}
