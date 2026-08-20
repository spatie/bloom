import Testing
import Foundation
@testable import BloomCore

// MARK: - A server that never was

/// Stands in for `codex app-server`. It reads the frames Bloom writes, answers requests from a
/// table the test fills, and can push notifications and server-to-client requests of its own.
///
/// The canned answers are the ones a real server sent, copied out of the recordings, so the client
/// is exercised against the shapes it will actually meet rather than against ones invented to suit
/// it.
private final class ScriptedCodexProcess: AgentProcessing, @unchecked Sendable {
    let launch: AgentLaunch

    private let lock = NSLock()
    private var written: [String] = []
    private var running = true
    private var replies: [String: JSONValue] = [:]
    private var failures: [String: (code: Int, message: String)] = [:]
    private var ignored: Set<String> = []

    private let stdoutContinuation: AsyncThrowingStream<String, Error>.Continuation
    private let stderrContinuation: AsyncStream<String>.Continuation

    let lines: AsyncThrowingStream<String, Error>
    let errorLines: AsyncStream<String>

    init(launch: AgentLaunch) {
        self.launch = launch

        var out: AsyncThrowingStream<String, Error>.Continuation!
        lines = AsyncThrowingStream(bufferingPolicy: .unbounded) { out = $0 }
        stdoutContinuation = out

        var err: AsyncStream<String>.Continuation!
        errorLines = AsyncStream(bufferingPolicy: .unbounded) { err = $0 }
        stderrContinuation = err
    }

    // MARK: Scripting

    func reply(to method: String, with result: JSONValue) {
        lock.lock(); replies[method] = result; lock.unlock()
    }

    func fail(_ method: String, code: Int, message: String) {
        lock.lock(); failures[method] = (code, message); lock.unlock()
    }

    /// A method the server simply never answers, which is what a hung request looks like.
    func ignore(_ method: String) {
        lock.lock(); ignored.insert(method); lock.unlock()
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

    var stdin: [String] {
        lock.lock(); defer { lock.unlock() }
        return written
    }

    /// The methods Bloom sent, in order, requests and notifications alike.
    var sentMethods: [String] {
        stdin.compactMap { JSONValue.parse($0)?["method"]?.stringValue }
    }

    func sentFrame(matching predicate: (JSONValue) -> Bool) -> JSONValue? {
        stdin.compactMap(JSONValue.parse).first(where: predicate)
    }

    // MARK: AgentProcessing

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    var exitStatus: Int32 { get async { 0 } }

    func writeLine(_ text: String) {
        lock.lock()
        written.append(text)
        let table = replies
        let refusals = failures
        let silent = ignored
        lock.unlock()

        guard let json = JSONValue.parse(text),
              let method = json["method"]?.stringValue,
              let id = json["id"],
              !silent.contains(method)
        else { return }

        if let refusal = refusals[method] {
            let error = JSONValue.object([
                "code": .integer(refusal.code),
                "message": .string(refusal.message),
            ])
            emit("{\"id\":\(id.compactJSON),\"error\":\(error.compactJSON)}")
            return
        }
        // Deliberately without a `jsonrpc` member, which is what the real server does.
        let result = table[method] ?? .object([:])
        emit("{\"id\":\(id.compactJSON),\"result\":\(result.compactJSON)}")
    }

    func closeStdin() {}

    func terminate() {
        endOutput()
    }

    func kill() {
        endOutput()
    }
}

/// Holds the script, because the process itself does not exist until `start()` launches it and a
/// test has to be able to say what the server will answer before that.
private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var made: ScriptedCodexProcess?
    private var replies: [String: JSONValue] = [:]
    private var failures: [String: (code: Int, message: String)] = [:]
    private var ignored: [String] = []

    func ignore(_ method: String) {
        lock.lock(); ignored.append(method); let live = made; lock.unlock()
        live?.ignore(method)
    }

    func reply(to method: String, with result: JSONValue) {
        lock.lock(); replies[method] = result; let live = made; lock.unlock()
        live?.reply(to: method, with: result)
    }

    func fail(_ method: String, code: Int, message: String) {
        lock.lock(); failures[method] = (code, message); let live = made; lock.unlock()
        live?.fail(method, code: code, message: message)
    }

    var factory: @Sendable (AgentLaunch) -> any AgentProcessing {
        { launch in
            let process = ScriptedCodexProcess(launch: launch)
            self.lock.lock()
            self.made = process
            let replies = self.replies
            let failures = self.failures
            let ignored = self.ignored
            self.lock.unlock()

            for (method, result) in replies { process.reply(to: method, with: result) }
            for (method, refusal) in failures {
                process.fail(method, code: refusal.code, message: refusal.message)
            }
            for method in ignored { process.ignore(method) }
            return process
        }
    }

    var process: ScriptedCodexProcess {
        lock.lock(); defer { lock.unlock() }
        return made!
    }
}

private func makeClient(_ box: ProcessBox, codexHome: String? = nil) -> CodexClient {
    CodexClient(
        configuration: CodexClient.Configuration(cwd: "/tmp/codex-work", codexHome: codexHome),
        makeProcess: box.factory
    )
}

/// Collects events off the client's stream from a task started before anything is emitted.
private actor EventCollector {
    private var collected: [CodexEvent] = []

    func consume(_ client: CodexClient, until predicate: @escaping @Sendable (CodexEvent) -> Bool) async {
        for await event in client.events {
            collected.append(event)
            if predicate(event) { return }
        }
    }

    var events: [CodexEvent] { collected }
}

// MARK: - Tests

@Suite struct CodexClientTests {
    @Test func launchesAppServerOnStdio() {
        let launch = CodexClient.launch(CodexClient.Configuration(
            cwd: "/tmp/w",
            codexHome: "/tmp/scratch-home"
        ))
        #expect(launch.executable == "codex")
        #expect(launch.arguments == ["app-server", "--listen", "stdio://"])
        #expect(launch.cwd == "/tmp/w")
        #expect(launch.environment["CODEX_HOME"] == "/tmp/scratch-home")
    }

    /// Absent means the user's own `CODEX_HOME`, which is what the app wants. A test that wanted a
    /// scratch one has to say so.
    @Test func leavesCodexHomeAloneWhenNoneIsGiven() {
        let launch = CodexClient.launch(CodexClient.Configuration(cwd: "/tmp/w", environment: [:]))
        #expect(launch.environment["CODEX_HOME"] == nil)
    }

    @Test func doesTheHandshakeInOrder() async throws {
        let box = ProcessBox()
        let client = makeClient(box)
        try await client.start()

        #expect(box.process.sentMethods == ["initialize", "initialized"])
        #expect(await client.isReady)

        // `initialized` is a notification and carries no id, which is what makes it a notification.
        let handshake = box.process.stdin.compactMap(JSONValue.parse)
        #expect(handshake[0]["id"] != nil)
        #expect(handshake[1]["id"] == nil)
        #expect(handshake[0]["params"]?["clientInfo"]?["name"]?.stringValue == "Bloom")
    }

    @Test func startsAThreadAndReadsItsIDOutOfTheReply() async throws {
        let box = ProcessBox()
        let client = makeClient(box)
        box.reply(to: "thread/start", with: .object([
            "thread": .object(["id": .string("01a02144-3b7e-7233-97f2-73ebd5105085")]),
            "model": .string("gpt-5.6-sol"),
            "reasoningEffort": .null,
        ]))

        try await client.start()
        let thread = try await client.startThread(
            model: "gpt-5.6-sol",
            approvalPolicy: .onRequest,
            sandbox: .workspaceWrite
        )

        #expect(thread.id == "01a02144-3b7e-7233-97f2-73ebd5105085")
        #expect(thread.model == "gpt-5.6-sol")
        #expect(thread.effort == nil)

        let start = try #require(box.process.sentFrame { $0["method"]?.stringValue == "thread/start" })
        // The kebab-case spelling, which is the one `thread/start` takes. `readOnly` here is
        // rejected outright by the real server.
        #expect(start["params"]?["sandbox"]?.stringValue == "workspace-write")
        #expect(start["params"]?["approvalPolicy"]?.stringValue == "on-request")
        #expect(start["params"]?["cwd"]?.stringValue == "/tmp/codex-work")
    }

    @Test func sendsATurnWithItsOwnModelAndEffort() async throws {
        let box = ProcessBox()
        let client = makeClient(box)
        box.reply(to: "turn/start", with: .object([
            "turn": .object([
                "id": .string("turn-1"),
                "status": .string("inProgress"),
                "items": .array([]),
            ]),
        ]))

        try await client.start()
        let turn = try await client.startTurn(
            threadID: "thread-1",
            input: [.text("hello"), .localImage(path: "/tmp/shot.png")],
            model: "gpt-5.6-luna",
            effort: "medium"
        )

        #expect(turn.id == "turn-1")
        #expect(turn.status == .inProgress)

        let sent = try #require(box.process.sentFrame { $0["method"]?.stringValue == "turn/start" })
        let params = try #require(sent["params"])
        #expect(params["model"]?.stringValue == "gpt-5.6-luna")
        #expect(params["effort"]?.stringValue == "medium")
        #expect(params["input"]?[0]?["type"]?.stringValue == "text")
        // An attachment is a path, which is exactly what Bloom's composer already produces.
        #expect(params["input"]?[1]?["type"]?.stringValue == "localImage")
        #expect(params["input"]?[1]?["path"]?.stringValue == "/tmp/shot.png")
    }

    /// An empty effort is left out rather than sent, because the server takes a non-empty string
    /// and a session that has never chosen one must not force a level on the model.
    @Test func leavesAnEmptyEffortOutOfTheTurn() async throws {
        let box = ProcessBox()
        let client = makeClient(box)
        try await client.start()
        _ = try? await client.startTurn(threadID: "t", input: [.text("hi")], effort: "")

        let sent = try #require(box.process.sentFrame { $0["method"]?.stringValue == "turn/start" })
        #expect(sent["params"]?["effort"] == nil)
    }

    @Test func interruptSendsBothIDs() async throws {
        let box = ProcessBox()
        let client = makeClient(box)
        try await client.start()
        try await client.interruptTurn(threadID: "thread-1", turnID: "turn-1")

        let sent = try #require(box.process.sentFrame { $0["method"]?.stringValue == "turn/interrupt" })
        // Without `turnId` the real server answers "Invalid request: missing field `turnId`".
        #expect(sent["params"]?["threadId"]?.stringValue == "thread-1")
        #expect(sent["params"]?["turnId"]?.stringValue == "turn-1")
    }

    @Test func aServerErrorReachesTheCallerAsAThrow() async throws {
        let box = ProcessBox()
        let client = makeClient(box)
        box.fail("thread/start", code: -32600, message: "Invalid request: unknown variant `readOnly`")

        try await client.start()
        await #expect(throws: CodexRPCError.self) {
            _ = try await client.startThread()
        }
    }

    /// A dead process must fail whatever is waiting rather than leaving a turn hung forever.
    @Test func endingTheProcessFailsEveryPendingRequest() async throws {
        let box = ProcessBox()
        box.ignore("thread/list")
        let client = makeClient(box)
        try await client.start()

        // A method the scripted server never answers, so the request is still outstanding.
        let pending = Task { try await client.send("thread/list", params: nil) }
        try await Task.sleep(for: .milliseconds(30))
        box.process.endOutput()

        await #expect(throws: CodexClientError.self) { try await pending.value }
    }

    @Test func replaysARecordedTurnAsEvents() async throws {
        let box = ProcessBox()
        let client = makeClient(box)
        try await client.start()

        let collector = EventCollector()
        let consuming = Task {
            await collector.consume(client) { event in
                if case .turnCompleted = event { return true }
                return false
            }
        }
        // Give the consumer a turn to attach before anything is pushed at it.
        try await Task.sleep(for: .milliseconds(20))

        for line in try bloomFixtureLines("codex-turn.ndjson") {
            // The recorded responses belong to the recording's own ids, not to this connection's,
            // so only the notifications are replayed.
            guard JSONValue.parse(line)?["method"] != nil else { continue }
            box.process.emit(line)
        }
        await consuming.value

        let events = await collector.events
        let deltas = events.compactMap { event -> String? in
            if case .agentMessageDelta(let delta) = event { return delta.text }
            return nil
        }
        #expect(deltas.joined() == "bloom")

        let completed = events.contains { event in
            if case .turnCompleted(let turn) = event { return turn.status == .completed }
            return false
        }
        #expect(completed)
    }

    /// The half a plain NDJSON reader cannot do: the server asks, and Bloom answers.
    @Test func answersAnApprovalTheServerAsked() async throws {
        let box = ProcessBox()
        let client = makeClient(box)
        try await client.start()

        let collector = EventCollector()
        let consuming = Task {
            await collector.consume(client) { event in
                if case .approval = event { return true }
                return false
            }
        }
        try await Task.sleep(for: .milliseconds(20))

        let ask = try bloomFixtureLines("codex-approval.ndjson").first { line in
            JSONValue.parse(line)?["method"]?.stringValue == "item/fileChange/requestApproval"
        }
        box.process.emit(try #require(ask))
        await consuming.value

        let approvals = await collector.events.compactMap { event -> CodexApprovalRequest? in
            if case .approval(let request) = event { return request }
            return nil
        }
        let request = try #require(approvals.first)
        #expect(request.kind == .fileChange)

        await client.answer(request, decision: .decline)
        let answer = try #require(box.process.stdin.last.flatMap(JSONValue.parse))
        // Addressed to the server's own id, which is zero here and is not one of ours.
        #expect(answer["id"]?.intValue == 0)
        #expect(answer["result"]?["decision"]?.stringValue == "decline")
    }

    /// The five server-to-client requests that are machinery rather than a question get a proper
    /// "method not found" instead of silence, so a turn fails visibly rather than hanging.
    @Test func refusesAServerRequestItDoesNotImplement() async throws {
        let box = ProcessBox()
        let client = makeClient(box)
        try await client.start()

        box.process.emit(#"{"id":3,"method":"attestation/generate","params":{}}"#)
        try await Task.sleep(for: .milliseconds(50))

        let refusal = try #require(box.process.stdin.last.flatMap(JSONValue.parse))
        #expect(refusal["id"]?.intValue == 3)
        #expect(refusal["error"]?["code"]?.intValue == -32601)
        #expect(refusal["error"]?["message"]?.stringValue?.contains("attestation/generate") == true)
    }

    /// The server writes tracing to stderr, which is why the frame stream never merges it. It is
    /// still kept, because it is the only explanation available when the process dies quietly.
    @Test func keepsStderrOutOfTheFramesAndInTheDiagnostics() async throws {
        let box = ProcessBox()
        let client = makeClient(box)
        try await client.start()

        box.process.emitError("ERROR codex_core::tools::router: error=patch rejected by user")
        try await Task.sleep(for: .milliseconds(50))

        #expect(await client.diagnostics.contains { $0.contains("patch rejected by user") })
    }
}
