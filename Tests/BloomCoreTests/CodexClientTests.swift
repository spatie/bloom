import Testing
import Foundation
@testable import BloomCore

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
