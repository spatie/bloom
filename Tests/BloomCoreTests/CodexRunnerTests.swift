import Testing
import Foundation
@testable import BloomCore

// MARK: - Fixtures

/// A repo, a workspace and a session in a throwaway database, because messages are foreign keyed
/// all the way up to a project.
private func makeCodexSession(
    _ store: Store,
    permissionMode: PermissionMode = .acceptEdits,
    agentSessionID: String? = nil
) async throws -> (Session, RepoID) {
    let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r-\(UUID().uuidString)"))
    let workspace = try await store.upsert(Workspace(
        repoID: repo.id, name: "w", branch: "b", path: "/tmp/w", baseBranch: "main"
    ))
    // Said out loud, and it was not. The fixture is named for Codex, ran through `CodexRunner`
    // and was left on the default backend, which was invisible until `Session` started holding
    // the mode and the backend legal against each other: Approve for me is a Codex row, so a
    // session claiming Claude Code cannot be in it, and this one silently became Auto.
    let session = try await store.upsert(Session(
        workspaceID: workspace.id,
        agentSessionID: agentSessionID,
        model: "gpt-5.6-sol",
        effort: "low",
        agentKind: .codex,
        permissionMode: permissionMode
    ))
    return (session, repo.id)
}

private func makeRunner(
    store: Store,
    session: Session,
    box: ProcessBox
) -> CodexRunner {
    CodexRunner(
        workspacePath: "/tmp/w",
        session: session,
        store: store,
        makeClient: { configuration in
            CodexClient(configuration: configuration, makeProcess: box.factory)
        }
    )
}

/// The reply a real `thread/start` sent, with the ids kept.
private let threadStartReply = JSONValue.object([
    "thread": .object(["id": .string("01a02144-3b7e-7233-97f2-73ebd5105085")]),
    "model": .string("gpt-5.6-sol"),
])

private let turnStartReply = JSONValue.object([
    "turn": .object([
        "id": .string("01a02144-3bab-7fe3-a92c-6eec594d84fd"),
        "status": .string("inProgress"),
        "items": .array([]),
    ]),
])

private func scriptedBox(onWrite: @escaping @Sendable (String) -> Void = { _ in }) -> ProcessBox {
    let box = ProcessBox(onWrite: onWrite)
    box.reply(to: "thread/start", with: threadStartReply)
    box.reply(to: "thread/resume", with: threadStartReply)
    box.reply(to: "turn/start", with: turnStartReply)
    return box
}

/// Waits for a condition the runner reaches on its own tasks, so a test never sleeps a fixed time.
private func eventually(
    _ description: String,
    within seconds: Double = 2,
    _ condition: @Sendable () async -> Bool
) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out waiting for \(description)")
}

// MARK: - Tests

@Suite(.scratchDirectory) struct CodexRunnerTests {
    @Test(arguments: [false, true])
    func lateStoppedCompletionCannotEndTheNextIntentionalTurn(delayStart: Bool) async throws {
        let store = try makeTestStore("codex-late-stop")
        let (session, _) = try await makeCodexSession(store)
        let box = scriptedBox()
        let runner = makeRunner(store: store, session: session, box: box)
        try await runner.send("first turn")
        runner.cancelNow()
        box.reply(to: "turn/start", with: .object([
            "turn": .object(["id": .string("new-turn"), "status": .string("inProgress"), "items": .array([])]),
        ]))
        if delayStart { box.ignore("turn/start") }
        let nextSend = Task { try await runner.send("new intentional turn") }
        await eventually("second turn start", within: 20) {
            box.process.sentMethods.filter { $0 == "turn/start" }.count == 2
        }
        if !delayStart { try await nextSend.value }
        box.process.emit(#"{"method":"item/started","params":{"threadId":"01a02144-3b7e-7233-97f2-73ebd5105085","turnId":"new-turn","item":{"id":"new-command","type":"commandExecution","command":"echo new","status":"inProgress"}}}"#)
        box.process.emit(#"{"method":"turn/completed","params":{"threadId":"01a02144-3b7e-7233-97f2-73ebd5105085","turn":{"id":"01a02144-3bab-7fe3-a92c-6eec594d84fd","status":"interrupted","items":[]}}}"#)
        box.process.emit(#"{"method":"item/completed","params":{"threadId":"01a02144-3b7e-7233-97f2-73ebd5105085","turnId":"new-turn","item":{"id":"new-text","type":"agentMessage","text":"still working"}}}"#)
        await eventually("new output after stale completion", within: 20) {
            (try? await store.messages(sessionID: session.id).contains { $0.kind == .assistantText }) == true
        }
        // A result delivered while turn/start is pending would clear TranscriptModel's busy
        // state. No result row is produced for this superseded completion either.
        #expect(try await store.messages(sessionID: session.id).filter { $0.kind == .result }.isEmpty)
        if delayStart {
            let starts = box.process.stdin.compactMap(JSONValue.parse).filter { $0["method"]?.stringValue == "turn/start" }
            let request = try #require(starts.last)
            let id = try #require(request["id"])
            box.process.emit("{\"id\":\(id.compactJSON),\"result\":{\"turn\":{\"id\":\"new-turn\",\"status\":\"inProgress\",\"items\":[]}}}")
            try await nextSend.value
        }
        #expect(try await store.session(id: session.id)?.state == .running)
        let interrupted = box.process.stdin.compactMap(JSONValue.parse).filter { $0["method"]?.stringValue == "turn/interrupt" }
        #expect(!interrupted.contains { $0["params"]?["turnId"]?.stringValue == "new-turn" })
        #expect(interrupted.contains { $0["params"]?["turnId"]?.stringValue == "01a02144-3bab-7fe3-a92c-6eec594d84fd" })
        box.process.emit(#"{"id":99,"method":"item/commandExecution/requestApproval","params":{"threadId":"01a02144-3b7e-7233-97f2-73ebd5105085","turnId":"new-turn","itemId":"new-command"}}"#)
        await eventually("new command approval after stale completion", within: 20) {
            ((try? await store.pendingPermissionAsks(sessionID: session.id)) ?? []).count == 1
        }
        let asks = try await store.pendingPermissionAsks(sessionID: session.id)
        #expect(asks.first?.ask.input["command"]?.stringValue == "echo new")
        runner.cancelNow()
        await eventually("new turn still interruptible", within: 20) {
            box.process.stdin.compactMap(JSONValue.parse).contains {
                $0["method"]?.stringValue == "turn/interrupt" && $0["params"]?["turnId"]?.stringValue == "new-turn"
            }
        }
        await runner.shutdown()
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["initialize", "thread/start", "turn/start"])
    func stopWhileStartingCannotBeLost(_ delayed: String) async throws {
        let store = try makeTestStore("codex-start-stop")
        let (session, _) = try await makeCodexSession(store)
        // Buffer the request itself: a polling deadline can expire before the send task is
        // scheduled when the full suite is running thousands of tests concurrently.
        let (requests, requestSink) = AsyncStream<String>.makeStream()
        defer { requestSink.finish() }
        let box = scriptedBox { requestSink.yield($0) }
        box.ignore(delayed)
        let runner = makeRunner(store: store, session: session, box: box)
        let sending = Task {
            defer { requestSink.finish() }
            do {
                try await runner.send("do not run after Stop")
                Issue.record("a cancelled send returned success")
            } catch is CancellationError {
                // Expected: the suspended send cannot cross the cancellation boundary.
            } catch {
                Issue.record("unexpected send error: \(error)")
            }
        }
        let frame = await requests.first { JSONValue.parse($0)?["method"]?.stringValue == delayed }
        let request = try #require(frame.flatMap(JSONValue.parse))
        let id = try #require(request["id"])
        runner.cancelNow()
        let reply: JSONValue = switch delayed {
        case "thread/start": threadStartReply
        case "turn/start": turnStartReply
        default: .object([:])
        }
        box.process.reply(to: delayed, with: reply)
        box.process.emit("{\"id\":\(id.compactJSON),\"result\":\(reply.compactJSON)}")
        await sending.value

        if delayed == "turn/start" {
            #expect(box.process.sentMethods.contains("turn/interrupt"))
        } else {
            #expect(!box.process.sentMethods.contains("turn/start"))
        }
        #expect(try await store.session(id: session.id)?.state != .running)
        try await runner.send("this new turn is intentional")
        #expect(try await store.session(id: session.id)?.state == .running)
        await runner.shutdown()
    }

    @Test func startsAThreadOnTheFirstTurnAndStoresItsID() async throws {
        let store = try makeTestStore("codex-runner-start")
        let (session, _) = try await makeCodexSession(store)
        let box = scriptedBox()
        let runner = makeRunner(store: store, session: session, box: box)

        try await runner.send("hello")

        let methods = box.process.sentMethods
        #expect(methods == ["initialize", "initialized", "thread/start", "turn/start"])

        // The thread id is written the moment it exists, which is what lets a crashed app resume.
        let stored = try await store.session(id: session.id)
        #expect(stored?.agentSessionID == "01a02144-3b7e-7233-97f2-73ebd5105085")
        #expect(stored?.state == .running)
    }

    @Test("Ask Bloom sends host instructions when starting and resuming Codex",
          arguments: [false, true], [false, true])
    func askBloomInstructions(hasWorkspace: Bool, resumed: Bool) async throws {
        let store = try makeTestStore("codex-ask-instructions")
        var session: Session
        if hasWorkspace {
            (session, _) = try await makeCodexSession(store)
        } else {
            session = Session(workspaceID: nil, agentKind: .codex)
        }
        if resumed { session.agentSessionID = "existing-chat" }
        session = try await store.upsert(session)
        let box = scriptedBox()
        let runner = makeRunner(store: store, session: session, box: box)

        try await runner.send("create a workspace and explore the project")

        let method = resumed ? "thread/resume" : "thread/start"
        let frame = try #require(box.process.sentFrame { $0["method"]?.stringValue == method })
        #expect(frame["params"]?["developerInstructions"]?.stringValue ==
                (hasWorkspace ? nil : AskConversation.instructions))
        #expect(frame["params"]?["baseInstructions"] == nil)
        await runner.shutdown()
    }

    @Test func childOutputAndCompletionNeverEnterOrFinishTheParentChat() async throws {
        let store = try makeTestStore("codex-child-isolation")
        let (session, _) = try await makeCodexSession(store)
        let box = scriptedBox()
        let runner = makeRunner(store: store, session: session, box: box)
        try await runner.send("work with a child")
        box.process.emit(#"{"method":"item/completed","params":{"threadId":"01a02144-3b7e-7233-97f2-73ebd5105085","turnId":"parent-turn","item":{"id":"root-self","type":"subAgentActivity","agentThreadId":"01a02144-3b7e-7233-97f2-73ebd5105085","agentPath":"/root","kind":"interacted"}}}"#)
        box.process.emit(#"{"method":"item/completed","params":{"threadId":"child","turnId":"child-turn","item":{"id":"child-text","type":"agentMessage","text":"Child-only output"}}}"#)
        box.process.emit(#"{"method":"turn/completed","params":{"threadId":"child","turn":{"id":"child-turn","status":"completed","items":[]}}}"#)
        box.process.emit(#"{"method":"item/completed","params":{"threadId":"01a02144-3b7e-7233-97f2-73ebd5105085","turnId":"parent-turn","item":{"id":"parent-text","type":"agentMessage","text":"Parent still working"}}}"#)
        await eventually("parent output after child completion") {
            (try? await store.messages(sessionID: session.id).contains { $0.kind == .assistantText }) == true
        }
        let rows = try await store.messages(sessionID: session.id)
        #expect(rows.filter { $0.kind == .assistantText }.count == 1)
        #expect(!rows.contains { $0.kind == .result })
        #expect(!rows.contains { String(decoding: $0.payload, as: UTF8.self).contains("root-self") })
        #expect(!rows.contains { String(decoding: $0.payload, as: UTF8.self).contains("Child-only output") })
        let current = try await store.session(id: session.id)
        #expect(current?.state == .running)
        await runner.shutdown()
    }

    @Test func startsTheStoredCodexExecutable() async throws {
        let store = try makeTestStore("codex-runner-executable")
        let (session, _) = try await makeCodexSession(store)
        try await store.setSetting(
            AgentCatalog.executablePathSettingKey(.codex),
            "/tmp/tools/codex"
        )
        let box = scriptedBox()
        let runner = makeRunner(store: store, session: session, box: box)

        try await runner.send("hello")

        #expect(box.process.launch.executable == "/tmp/tools/codex")
    }

    @Test func childApprovalsCannotBorrowParentMetadataOrSendReasonsToTheParent() async throws {
        let store = try makeTestStore("codex-child-approval")
        let (session, repoID) = try await makeCodexSession(store)
        try await store.upsert(PermissionGrant(repoID: repoID, toolName: "Bash", ruleContent: "echo parent"))
        let box = scriptedBox()
        box.reply(to: "turn/steer", with: .object([:]))
        let runner = makeRunner(store: store, session: session, box: box)
        try await runner.send("review")
        box.process.emit(#"{"method":"item/completed","params":{"threadId":"01a02144-3b7e-7233-97f2-73ebd5105085","turnId":"parent-turn","item":{"id":"spawn","type":"subAgentActivity","agentThreadId":"child","agentPath":"/root/review","kind":"started"}}}"#)
        box.process.emit(#"{"method":"item/started","params":{"threadId":"01a02144-3b7e-7233-97f2-73ebd5105085","turnId":"parent-turn","item":{"id":"shared","type":"commandExecution","command":"echo parent","status":"inProgress"}}}"#)
        box.process.emit(#"{"method":"item/started","params":{"threadId":"child","turnId":"child-turn","item":{"id":"shared","type":"commandExecution","command":"echo child","status":"inProgress"}}}"#)
        box.process.emit(#"{"id":55,"method":"item/commandExecution/requestApproval","params":{"threadId":"child","turnId":"child-turn","itemId":"shared"}}"#)
        await eventually("child permission to remain pending") {
            ((try? await store.pendingPermissionAsks(sessionID: session.id)) ?? []).count == 1
        }
        let asks = try await store.pendingPermissionAsks(sessionID: session.id)
        let ask = try #require(asks.first).ask
        #expect(ask.input["command"]?.stringValue == "echo child")
        await runner.answer(requestID: ask.requestID, decision: .deny(message: "Use a read-only check", endsTurn: false))
        let steer = try #require(box.process.sentFrame { $0["method"]?.stringValue == "turn/steer" })
        #expect(steer["params"]?["threadId"]?.stringValue == "child")
        #expect(steer["params"]?["expectedTurnId"]?.stringValue == "child-turn")
        await runner.shutdown()
    }

    @Test func aQuestionAnswerUsesTheCodexWireShapeAndResolvedQuestionsDisappear() async throws {
        let store = try makeTestStore("codex-question-answer")
        let (session, _) = try await makeCodexSession(store)
        let box = scriptedBox()
        let runner = makeRunner(store: store, session: session, box: box)
        try await runner.send("ask me")
        box.process.emit(#"{"id":71,"method":"item/tool/requestUserInput","params":{"threadId":"01a02144-3b7e-7233-97f2-73ebd5105085","turnId":"parent-turn","itemId":"question","isBlocking":false,"questions":[{"id":"scope","header":"Scope","question":"Which scope?","options":[{"label":"All","description":"Everything"}]}]}}"#)
        await eventually("question card") {
            ((try? await store.pendingPermissionAsks(sessionID: session.id)) ?? []).count == 1
        }
        let asks = try await store.pendingPermissionAsks(sessionID: session.id)
        let ask = try #require(asks.first).ask
        #expect(ask.toolName == AgentQuestionnaire.toolName)
        let answered = AgentQuestionnaire.answered(ask.input, answers: ["scope": "All"])
        await runner.answer(requestID: ask.requestID, decision: .answer(input: answered))
        let reply = try #require(box.process.sentFrame { $0["id"]?.intValue == 71 && $0["result"] != nil })
        #expect(reply["result"]?["answers"]?["scope"]?["answers"]?[0]?.stringValue == "All")
        box.process.emit(#"{"id":72,"method":"item/tool/requestUserInput","params":{"threadId":"01a02144-3b7e-7233-97f2-73ebd5105085","turnId":"parent-turn","itemId":"question-2","questions":[{"id":"note","header":"Note","question":"Anything else?"}]}}"#)
        box.process.emit(#"{"method":"serverRequest/resolved","params":{"threadId":"01a02144-3b7e-7233-97f2-73ebd5105085","requestId":72}}"#)
        box.process.emit(#"{"method":"item/completed","params":{"threadId":"01a02144-3b7e-7233-97f2-73ebd5105085","turnId":"parent-turn","item":{"id":"sentinel","type":"agentMessage","text":"Question resolved"}}}"#)
        await eventually("resolution processed before following prose") {
            (try? await store.messages(sessionID: session.id).contains { $0.kind == .assistantText }) == true
        }
        let pending = try await store.pendingPermissionAsks(sessionID: session.id)
        #expect(pending.isEmpty)
        await runner.shutdown()
    }

    /// A chat that has spoken before resumes rather than starting a second conversation.
    @Test func resumesAThreadItAlreadyHas() async throws {
        let store = try makeTestStore("codex-runner-resume")
        let (session, _) = try await makeCodexSession(store, agentSessionID: "01a02144-3b7e-7233-97f2-73ebd5105085")
        let box = scriptedBox()
        let runner = makeRunner(store: store, session: session, box: box)

        try await runner.send("again")

        #expect(box.process.sentMethods.contains("thread/resume"))
        #expect(!box.process.sentMethods.contains("thread/start"))
    }

    @Test func writesTheUsersOwnWordsAsARowTheTranscriptAlreadyDraws() async throws {
        let store = try makeTestStore("codex-runner-user")
        let (session, _) = try await makeCodexSession(store)
        let box = scriptedBox()
        let runner = makeRunner(store: store, session: session, box: box)

        try await runner.send("write the tests first")

        let rows = try await store.messages(sessionID: session.id)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.kind == .user)

        // Byte for byte the shape `AgentRunner` writes, because it is the same row in the same
        // table drawn by the same view. A user row is drawn from its payload and its kind column
        // rather than from a decoded event: `AgentEvent` only reads a `user` line when it carries
        // a tool result, so this is what the transcript actually reads.
        let json = try #require(JSONValue.parse(row.payload))
        #expect(json["type"]?.stringValue == "user")
        #expect(json["message"]?["content"]?[0]?["text"]?.stringValue == "write the tests first")
    }

    /// Model, effort, approval policy and sandbox all travel with the turn, which is what lets a
    /// composer chip take effect on the next turn without restarting anything.
    @Test func sendsTheChatsModelAndEffortWithEveryTurn() async throws {
        let store = try makeTestStore("codex-runner-turn")
        let (session, _) = try await makeCodexSession(store)
        let box = scriptedBox()
        let runner = makeRunner(store: store, session: session, box: box)

        try await runner.send("hello")

        let turn = try #require(box.process.sentFrame { $0["method"]?.stringValue == "turn/start" })
        let params = try #require(turn["params"])
        #expect(params["model"]?.stringValue == "gpt-5.6-sol")
        #expect(params["effort"]?.stringValue == "low")
        #expect(params["approvalPolicy"]?.stringValue == "on-request")
        #expect(params["sandboxPolicy"]?["type"]?.stringValue == "workspaceWrite")
        // A Codex chat may write where its own worktree is, and nowhere else.
        #expect(params["sandboxPolicy"]?["writableRoots"]?[0]?.stringValue == "/tmp/w")
        // Named on every turn, not only on the turn that wants a reviewer of its own. The field
        // is sticky on this protocol, so a mode that left it out would inherit whatever the last
        // turn asked for.
        #expect(params["approvalsReviewer"]?.stringValue == "user")
    }

    @Test func mapsEveryPermissionModeOntoThePolicySandboxAndReviewerTriple() {
        #expect(CodexRunner.approvalPolicy(for: .bypassPermissions) == .never)
        #expect(CodexRunner.sandboxMode(for: .bypassPermissions) == .dangerFullAccess)
        #expect(CodexRunner.approvalPolicy(for: .acceptEdits) == .onRequest)
        #expect(CodexRunner.sandboxMode(for: .acceptEdits) == .workspaceWrite)
        #expect(CodexRunner.approvalPolicy(for: .auto) == .onRequest)
        // Read only means do not write without telling me, and read-only is the sandbox for it.
        #expect(CodexRunner.sandboxMode(for: .auto) == .readOnly)

        // The four are Codex's own four presets: read-only, workspace, auto, full-access.
        for mode in [PermissionMode.auto, .acceptEdits, .bypassPermissions, .plan] {
            #expect(CodexRunner.approvalsReviewer(for: mode) == .user)
        }
    }

    /// The bug a user reported: Bloom's Codex menu had no row for the preset the Codex app calls
    /// "Approve for me", so the only mode that reaches Codex's own reviewer was unreachable.
    /// Approve for me and Ask for approval differ in exactly one field, which is who answers.
    @Test func approveForMeIsAskForApprovalWithCodexsOwnReviewerAnswering() {
        #expect(CodexRunner.approvalsReviewer(for: .autoReview) == .autoReview)
        #expect(CodexRunner.approvalsReviewer(for: .acceptEdits) == .user)
        #expect(CodexRunner.approvalPolicy(for: .autoReview) == CodexRunner.approvalPolicy(for: .acceptEdits))
        #expect(CodexRunner.sandboxMode(for: .autoReview) == CodexRunner.sandboxMode(for: .acceptEdits))
        // The value the server parses. Measured against codex 0.149.1, which rejects anything
        // else with "unknown variant, expected one of `user`, `auto_review`, `guardian_subagent`".
        #expect(CodexApprovalsReviewer.autoReview.rawValue == "auto_review")
        #expect(CodexApprovalsReviewer.user.rawValue == "user")
    }

    @Test func sendsTheReviewerWithTheTurnWhenApproveForMeIsChosen() async throws {
        let store = try makeTestStore("codex-runner-approve-for-me")
        let (session, _) = try await makeCodexSession(store, permissionMode: .autoReview)
        let box = scriptedBox()
        let runner = makeRunner(store: store, session: session, box: box)

        try await runner.send("hello")

        let turn = try #require(box.process.sentFrame { $0["method"]?.stringValue == "turn/start" })
        let params = try #require(turn["params"])
        #expect(params["approvalsReviewer"]?.stringValue == "auto_review")
        #expect(params["sandboxPolicy"]?["type"]?.stringValue == "workspaceWrite")
    }

    @Test func replaysARecordedTurnIntoTheTranscript() async throws {
        let store = try makeTestStore("codex-runner-replay")
        let (session, _) = try await makeCodexSession(store)
        let box = scriptedBox()
        let runner = makeRunner(store: store, session: session, box: box)

        try await runner.send("Reply with exactly one word: bloom")
        for line in try bloomFixtureLines("codex-turn.ndjson") {
            guard JSONValue.parse(line)?["method"] != nil else { continue }
            box.process.emit(line)
        }

        await eventually("the turn to finish") {
            (try? await store.session(id: session.id))??.state == .idle
        }

        let rows = try await store.messages(sessionID: session.id)
        // The prompt, the line that opens a transcript, the reply, the rate limit reading and the
        // line that closes the turn. The two agent message deltas are drawn and dropped: storing
        // them would write the reply twice.
        #expect(rows.map(\.kind) == [.user, .system, .assistantText, .notice, .result])

        let stored = try #require(try await store.session(id: session.id))
        #expect(stored.outputTokens == 6)
        #expect(stored.inputTokens == 16159)
        // No price reaches this protocol, and a zero that means "we do not know" must never be
        // added to one that means dollars.
        #expect(stored.costUSD == 0)
    }

    @Test func aStoppedTurnIsCancelledRatherThanFailed() async throws {
        let store = try makeTestStore("codex-runner-stop")
        let (session, _) = try await makeCodexSession(store)
        let box = scriptedBox()
        let runner = makeRunner(store: store, session: session, box: box)

        try await runner.send("count to three hundred")
        runner.cancelNow()

        await eventually("the interrupt to reach the server") {
            box.process.sentMethods.contains("turn/interrupt")
        }
        let interrupt = try #require(box.process.sentFrame { $0["method"]?.stringValue == "turn/interrupt" })
        // Both ids, because the server refuses a thread id on its own.
        #expect(interrupt["params"]?["threadId"]?.stringValue == "01a02144-3b7e-7233-97f2-73ebd5105085")
        #expect(interrupt["params"]?["turnId"]?.stringValue == "01a02144-3bab-7fe3-a92c-6eec594d84fd")

        for line in try bloomFixtureLines("codex-interrupt.ndjson") {
            guard let json = JSONValue.parse(line), json["method"]?.stringValue == "turn/completed" else {
                continue
            }
            box.process.emit(line)
        }
        await eventually("the session to settle") {
            (try? await store.session(id: session.id))??.state == .cancelled
        }
    }

    /// The whole point of the permission wire: the question reaches a person, the turn waits, and
    /// answering it puts a word back on the connection.
    @Test func asksTheQuestionTheServerAskedAndAnswersIt() async throws {
        let store = try makeTestStore("codex-runner-ask")
        let (session, _) = try await makeCodexSession(store)
        let box = scriptedBox()
        let runner = makeRunner(store: store, session: session, box: box)

        try await runner.send("create note.txt")
        for line in try bloomFixtureLines("codex-approval.ndjson") {
            guard let json = JSONValue.parse(line), let method = json["method"]?.stringValue else {
                continue
            }
            guard method == "item/started" || method.hasSuffix("requestApproval") else { continue }
            box.process.emit(line)
        }

        await eventually("the question to be stored") {
            ((try? await store.pendingPermissionAsks(sessionID: session.id)) ?? []).isEmpty == false
        }

        let asks = try await store.pendingPermissionAsks(sessionID: session.id)
        let ask = try #require(asks.first).ask
        #expect(ask.toolName == "ApplyPatch")
        #expect(ask.subject.hasSuffix("note.txt"))

        // The chat is alive, costing nothing and doing nothing, and that has to be visible from
        // outside the workspace.
        await eventually("the session to say it is waiting") {
            (try? await store.session(id: session.id))??.state == .waiting
        }

        await runner.answer(requestID: ask.requestID, decision: .deny(message: "no", endsTurn: false))

        await eventually("the refusal to reach the server") {
            box.process.stdin.contains { $0.contains("\"decline\"") }
        }
        let answered = try await store.pendingPermissionAsks(sessionID: session.id)
        #expect(answered.isEmpty)
    }

    /// A rule the user approved for this project answers the question without troubling them, and
    /// says so in the transcript. The same behaviour as the Claude Code side, on a protocol that
    /// has no rules of its own.
    @Test func aStoredGrantAnswersTheQuestionWithoutAsking() async throws {
        let store = try makeTestStore("codex-runner-grant")
        let (session, repoID) = try await makeCodexSession(store)
        let box = scriptedBox()
        let runner = makeRunner(store: store, session: session, box: box)

        // The paths the recorded patch touches.
        let paths = try bloomFixtureLines("codex-approval.ndjson")
            .compactMap { line -> String? in
                guard let json = JSONValue.parse(line),
                      json["method"]?.stringValue == "item/started",
                      json["params"]?["item"]?["type"]?.stringValue == "fileChange"
                else { return nil }
                return json["params"]?["item"]?["changes"]?[0]?["path"]?.stringValue
            }
        // Required here rather than in the call below: `ruleContent` is itself optional, so a
        // `#require` written in that position resolves to the overload that hands the optional
        // straight through and asserts nothing. A fixture that stopped naming a path would then
        // have granted the whole tool, and this test would have passed for the wrong reason.
        let path = try #require(paths.first)
        try await store.upsert(PermissionGrant(
            repoID: repoID,
            toolName: "ApplyPatch",
            ruleContent: path
        ))

        let watching = Task { () -> PermissionResolution? in
            for await event in runner.events {
                if case .permissionDecided(let resolution) = event { return resolution }
            }
            return nil
        }

        try await runner.send("create note.txt")
        for line in try bloomFixtureLines("codex-approval.ndjson") {
            guard let json = JSONValue.parse(line), let method = json["method"]?.stringValue else {
                continue
            }
            guard method == "item/started" || method.hasSuffix("requestApproval") else { continue }
            box.process.emit(line)
        }

        let resolution = try #require(await watching.value)
        #expect(resolution.decision == PermissionAskOutcome.auto)
        #expect(resolution.note.contains("ApplyPatch"))
        // Answered on the wire as "stop asking for this session", and nothing written to any file
        // belonging to the user.
        await eventually("the automatic answer to reach the server") {
            box.process.stdin.contains { $0.contains("acceptForSession") }
        }
    }

    /// Stop is an interrupt and nothing more, which is what lets the next message land in the same
    /// server with the grants the person already gave it. Killing on every Stop would throw those
    /// away, because `acceptForSession` is remembered by the process rather than by Bloom.
    @Test func stopInterruptsTheTurnAndLeavesTheServerRunning() async throws {
        let store = try makeTestStore("codex-runner-stop-keeps-server")
        let (session, _) = try await makeCodexSession(store)
        let box = scriptedBox()
        let runner = makeRunner(store: store, session: session, box: box)

        try await runner.send("count to three hundred")
        runner.cancelNow()
        await eventually("the interrupt to reach the server") {
            box.process.sentMethods.contains("turn/interrupt")
        }
        for line in try bloomFixtureLines("codex-interrupt.ndjson") {
            guard let json = JSONValue.parse(line), json["method"]?.stringValue == "turn/completed" else {
                continue
            }
            box.process.emit(line)
        }
        await eventually("the session to settle") {
            (try? await store.session(id: session.id))??.state == .cancelled
        }

        #expect(box.process.isRunning)
        #expect(await runner.isProcessAlive)

        // And the chat is sendable again, on the same connection: one handshake, two turns.
        try await runner.send("carry on")
        #expect(box.process.sentMethods.filter { $0 == "initialize" }.count == 1)
        #expect(box.process.sentMethods.filter { $0 == "turn/start" }.count == 2)
    }

    /// The orphaned-children bug. Quit, close and archive all mean the server goes, and nothing in
    /// this runner used to signal it at all: the interrupt closed the turn, the quit poll read
    /// that as the process being gone, and `codex app-server` carried on with its working
    /// directory inside a worktree that was about to be deleted.
    @Test func tearingDownKillsTheServer() async throws {
        let store = try makeTestStore("codex-runner-terminate")
        let (session, _) = try await makeCodexSession(store)
        let box = scriptedBox()
        let runner = makeRunner(store: store, session: session, box: box)

        try await runner.send("count to three hundred")
        #expect(box.process.isRunning)

        runner.terminateNow()

        // Signalled synchronously, because archive removes the worktree the moment this returns.
        #expect(box.process.isRunning == false)
        #expect(await runner.isProcessAlive == false)
    }

    /// What the signal cannot do, the bookkeeping behind it must: a chat torn down mid question
    /// keeps live buttons on a row nobody can answer any more, and the next launch's sweep files
    /// it as "Bloom was not running when this was asked", which is not what happened.
    @Test func tearingDownFilesTheQuestionNobodyAnswered() async throws {
        let store = try makeTestStore("codex-runner-terminate-ask")
        let (session, _) = try await makeCodexSession(store)
        let box = scriptedBox()
        let runner = makeRunner(store: store, session: session, box: box)

        let watching = Task { () -> PermissionResolution? in
            for await event in runner.events {
                if case .permissionDecided(let resolution) = event { return resolution }
            }
            return nil
        }

        try await runner.send("create note.txt")
        for line in try bloomFixtureLines("codex-approval.ndjson") {
            guard let json = JSONValue.parse(line), let method = json["method"]?.stringValue else {
                continue
            }
            guard method == "item/started" || method.hasSuffix("requestApproval") else { continue }
            box.process.emit(line)
        }
        await eventually("the question to be stored") {
            ((try? await store.pendingPermissionAsks(sessionID: session.id)) ?? []).isEmpty == false
        }
        let ask = try #require(try await store.pendingPermissionAsks(sessionID: session.id).first).ask

        runner.terminateNow()

        let resolution = try #require(await watching.value)
        #expect(resolution.requestID == ask.requestID)
        #expect(resolution.decision == PermissionAskOutcome.stopped)

        await eventually("the question to be settled in the database") {
            ((try? await store.pendingPermissionAsks(sessionID: session.id)) ?? []).isEmpty
        }
        let decisions = try await store.permissionAskDecisions(sessionID: session.id)
        #expect(decisions[ask.requestID] == PermissionAskOutcome.stopped)
        #expect(decisions[ask.requestID] != PermissionAskOutcome.abandoned)
    }

    /// Killing the server does not end the conversation. The thread id is on the session row, so
    /// the next message connects again and resumes rather than starting a second conversation.
    @Test func aChatWhoseServerWasKilledResumesOnTheNextMessage() async throws {
        let store = try makeTestStore("codex-runner-terminate-resume")
        let (session, _) = try await makeCodexSession(store)
        let box = scriptedBox()
        let runner = makeRunner(store: store, session: session, box: box)

        try await runner.send("hello")
        runner.terminateNow()
        // Cancellation must only be published after detaching the dying connection. CI caught
        // a new send finding that client while the old shutdown was still awaiting its stop.
        await eventually("the teardown to finish") {
            (try? await store.session(id: session.id))??.state == .cancelled
        }

        try await runner.send("again")

        // A second process, and it resumes the thread the first one started.
        #expect(box.process.sentMethods == ["initialize", "initialized", "thread/resume", "turn/start"])
        #expect(box.process.isRunning)
    }

    /// A view that stops drawing must not stop the agent.
    @Test func handsEveryConsumerItsOwnStream() async throws {
        let store = try makeTestStore("codex-runner-streams")
        let (session, _) = try await makeCodexSession(store)
        let box = scriptedBox()
        let runner = makeRunner(store: store, session: session, box: box)

        let first = Task {
            for await event in runner.events {
                if case .initialized = event { return true }
            }
            return false
        }
        let second = Task {
            for await event in runner.events {
                if case .initialized = event { return true }
            }
            return false
        }

        try await runner.send("hello")
        box.process.emit(#"{"method":"thread/started","params":{"thread":{"id":"01a02144-3b7e-7233-97f2-73ebd5105085"}}}"#)

        #expect(await first.value)
        #expect(await second.value)
    }
}

// MARK: - The column

@Suite(.scratchDirectory) struct SessionAgentKindTests {
    /// Every chat that existed before the column did was a Claude Code chat, and the default has
    /// to say so rather than leaving a value nothing can read.
    @Test func aChatDefaultsToClaudeCode() async throws {
        let store = try makeTestStore("agent-kind-default")
        // A chat made here rather than through `makeCodexSession`, which now says which backend
        // it is for. A test about the default cannot borrow a fixture that names one.
        let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r-\(UUID().uuidString)"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "w", branch: "b", path: "/tmp/w", baseBranch: "main"
        ))
        let session = try await store.upsert(Session(workspaceID: workspace.id))
        #expect(session.agentKind == .claudeCode)

        let stored = try await store.session(id: session.id)
        #expect(stored?.agentKind == .claudeCode)
    }

    @Test func theColumnSurvivesARoundTrip() async throws {
        let store = try makeTestStore("agent-kind-roundtrip")
        let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r-\(UUID().uuidString)"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "w", branch: "b", path: "/tmp/w", baseBranch: "main"
        ))
        let session = try await store.upsert(Session(workspaceID: workspace.id, agentKind: .codex))

        #expect(try await store.session(id: session.id)?.agentKind == .codex)
        let listed = try await store.sessions(workspaceID: workspace.id)
        #expect(listed.first?.agentKind == .codex)
    }

    /// The picker changes the backend of a chat that has not spoken yet, and that write must not
    /// put back anything else: `updateSessionPreferences` is narrow for the same reason it always
    /// was, and the runner's own columns are not its to touch.
    @Test func changingTheBackendLeavesTheRunnersColumnsAlone() async throws {
        let store = try makeTestStore("agent-kind-narrow")
        let (session, _) = try await makeCodexSession(store)

        try await store.update(sessionID: session.id) {
            $0.agentSessionID = "thread-1"
            $0.inputTokens = 42
        }
        try await store.updateSessionPreferences(id: session.id, agentKind: .codex)

        let stored = try #require(try await store.session(id: session.id))
        #expect(stored.agentKind == .codex)
        #expect(stored.agentSessionID == "thread-1")
        #expect(stored.inputTokens == 42)
    }

    // MARK: - The context window

    /// The one composer setting that cannot travel with the turn: it is a `-c` override read when
    /// `codex app-server` starts, so a chat set to it before its first turn has to be launched
    /// with it. See `CodexContextWindow`.
    @Test func launchesTheServerWithTheWindowTheChatIsSetTo() async throws {
        let store = try makeTestStore("codex-runner-window")
        let (session, _) = try await makeCodexSession(store)
        try await store.setSetting(
            ComposerControls.contextWindowKey(sessionID: session.id), "1000000"
        )
        let box = scriptedBox()
        let runner = makeRunner(store: store, session: session, box: box)

        try await runner.send("hello")

        let arguments = box.process.launch.arguments
        #expect(arguments.contains("model_context_window=1000000"))
        #expect(arguments.contains("model_auto_compact_token_limit=900000"))
    }

    /// **The bug this exists to stop:** every other chip takes effect on the next turn, so a
    /// window changed mid chat looked like it had too, while the long-lived server went on running
    /// on the size it was started with. Changing it starts another server, and the thread id on
    /// the row is what makes that a resume rather than a new conversation.
    @Test func startsAnotherServerWhenTheWindowChangesMidChat() async throws {
        let store = try makeTestStore("codex-runner-window-change")
        let (session, _) = try await makeCodexSession(store)
        let box = scriptedBox()
        let runner = makeRunner(store: store, session: session, box: box)

        try await runner.send("first")
        #expect(box.processes.count == 1)
        #expect(!box.process.launch.arguments.contains("model_context_window=500000"))

        try await store.setSetting(
            ComposerControls.contextWindowKey(sessionID: session.id), "500000"
        )
        try await runner.send("second")

        #expect(box.processes.count == 2)
        #expect(box.process.launch.arguments.contains("model_context_window=500000"))
        // The conversation goes with it. Anything else would make a picker press a way to lose
        // the chat that is on screen.
        #expect(box.process.sentMethods.contains("thread/resume"))
    }

    /// A reconnect costs the grants that live only inside the server, so it happens when the value
    /// has actually changed and not on every turn.
    @Test func leavesTheServerAloneWhenTheWindowHasNotChanged() async throws {
        let store = try makeTestStore("codex-runner-window-same")
        let (session, _) = try await makeCodexSession(store)
        try await store.setSetting(
            ComposerControls.contextWindowKey(sessionID: session.id), "500000"
        )
        let box = scriptedBox()
        let runner = makeRunner(store: store, session: session, box: box)

        try await runner.send("first")
        try await runner.send("second")

        #expect(box.processes.count == 1)
    }

    /// Every migration step has to survive being replayed over a database that already has it
    /// applied, because `ADD COLUMN` has no `IF NOT EXISTS` and rewinding `user_version` is how an
    /// old schema is reproduced. A step that threw here would take the whole transaction with it
    /// and leave a database no version number describes.
    @Test func theMigrationSurvivesBeingReplayed() async throws {
        let path = TestScratch.unique("agent-kind-replay") + ".sqlite"
        let store = try Store(path: path)
        let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r-\(UUID().uuidString)"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "w", branch: "b", path: "/tmp/w", baseBranch: "main"
        ))
        let session = try await store.upsert(Session(workspaceID: workspace.id, agentKind: .codex))

        let raw = try SQLiteDatabase(path: path)
        try raw.setUserVersion(0)

        let reopened = try Store(path: path)
        let sessions = try await reopened.sessions(workspaceID: workspace.id)
        #expect(sessions.count == 1)
        #expect(sessions.first?.id == session.id)
        // Replaying must not put the column back to its default either.
        #expect(sessions.first?.agentKind == .codex)
    }
}

@Suite("Side conversation Codex transport", .scratchDirectory)
struct SideConversationCodexRunnerTests {
    @Test func failedStartRetriesWithContextWithoutChangingTheEditableQuestion() async throws {
        let store = try makeTestStore("side-codex-wire")
        let (createdParent, _) = try await makeCodexSession(store, agentSessionID: "parent-thread")
        let parent = try #require(try await store.session(id: createdParent.id))
        let child = try await store.openSideConversation(parentID: parent.id, streamingText: "Original context")
        let box = scriptedBox()
        let runner = makeRunner(store: store, session: child, box: box)
        box.fail("turn/start", code: -32000, message: "Try again")
        do {
            try await runner.send("Why?")
            Issue.record("Expected the scripted first start to fail")
        } catch {
            #expect((error as? CodexRPCError)?.message == "Try again")
        }
        #expect(try await store.setting(SideConversation.contextDeliveredKey(child.id)) == nil)
        await runner.shutdown()
        let resumed = try #require(try await store.session(id: child.id))
        let retryBox = scriptedBox()
        let retryRunner = makeRunner(store: store, session: resumed, box: retryBox)
        try await retryRunner.send("Why?")
        let frames = box.process.stdin + retryBox.process.stdin
        let starts = frames.compactMap(JSONValue.parse).filter { $0["method"]?.stringValue == "turn/start" }
        #expect(starts.count == 2)
        for start in starts {
            #expect(start["params"]?["input"]?[0]?["text"]?.stringValue?.contains("Original context") == true)
        }
        #expect(!box.process.sentMethods.contains("thread/resume"))
        #expect(try await store.setting(SideConversation.contextDeliveredKey(child.id)) == "1")
        let messages = try await store.messages(sessionID: child.id).filter { $0.kind == .user }
        #expect(messages.allSatisfy { UserTurnPrompt.text(in: $0.payload) == "Why?" })
        #expect(try await store.session(id: parent.id) == parent)
        await retryRunner.shutdown()
    }
}
