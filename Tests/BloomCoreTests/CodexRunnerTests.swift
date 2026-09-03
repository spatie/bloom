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

private func scriptedBox() -> ProcessBox {
    let box = ProcessBox()
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
        // The connection is dropped by the bookkeeping behind the signal, not by the signal.
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
        raw.userVersion = 0

        let reopened = try Store(path: path)
        let sessions = try await reopened.sessions(workspaceID: workspace.id)
        #expect(sessions.count == 1)
        #expect(sessions.first?.id == session.id)
        // Replaying must not put the column back to its default either.
        #expect(sessions.first?.agentKind == .codex)
    }
}
