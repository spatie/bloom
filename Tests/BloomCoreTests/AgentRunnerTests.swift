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

/// What the agent is actually launched with.
///
/// This suite already existed, and it pinned the invocation with an exact array, which is normally
/// the strongest shape a test can take. It still missed `--effort` for as long as the composer has
/// offered a reasoning picker, because the array was written from docs/PROTOCOL.md rather than from
/// what the app lets somebody choose. Every level anyone picked was written to the session row,
/// read back into the menu, and went no further.
///
/// So the rule the suite now encodes is the other one: **every composer control has to be visible
/// here**. A control that cannot be found in this array is decoration, and asserting the array is
/// what the file said before is not the same as asserting it is right.
///
/// Everything below was checked against the installed CLI (2.1.238) by running it, not assumed.
/// `--effort` and `--thinking` are both real and both hidden from `--help`'s summary, and they
/// differ on a bad value in a way that matters: `--effort` warns on stderr and carries on with
/// exit 0, `--thinking` exits 1. The output style has no flag at all, only a settings key, so it
/// travels inside `--settings`, which is documented and takes a JSON string as well as a path.
@Suite("AgentRunner argv", .tags(.agentProtocol), .scratchDirectory)
struct AgentRunnerArgvTests {
    /// Reads the value after a flag, so an assertion says what it means rather than counting
    /// indexes.
    private func value(of flag: String, in argv: [String]) -> String? {
        guard let index = argv.firstIndex(of: flag), argv.indices.contains(index + 1) else { return nil }
        return argv[index + 1]
    }

    @Test("builds the invocation docs/PROTOCOL.md specifies")
    func buildsArgv() {
        let session = Session(workspaceID: "w", model: "opus", effort: "high", permissionMode: .acceptEdits)
        #expect(AgentRunner.argv(session: session, resume: nil) == [
            "-p",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--permission-mode", "acceptEdits",
            "--permission-prompt-tool", "stdio",
            "--model", "opus",
            "--effort", "high",
        ])
    }

    /// Always on, for every session, and this is where that decision is pinned.
    ///
    /// Without the flag the CLI answers permission questions itself and the answer is no. With it
    /// the CLI asks. It does not make the CLI ask more often: the classifier still approves
    /// everything it approved before, measured at zero questions across seven tool calls in one
    /// ordinary turn under `acceptEdits`. The only calls that reach the wire are the ones that are
    /// silently refused today.
    @Test("every session can be asked, whatever mode it is in")
    func alwaysAsks() {
        for mode in PermissionMode.allCases {
            let argv = AgentRunner.argv(session: Session(workspaceID: "w", permissionMode: mode), resume: nil)

            #expect(value(of: "--permission-prompt-tool", in: argv) == "stdio")
        }
    }

    // MARK: Effort

    @Test("the reasoning effort the user picked reaches the CLI")
    func passesEffort() {
        let session = Session(workspaceID: "w", effort: "high")

        #expect(value(of: "--effort", in: AgentRunner.argv(session: session, resume: nil)) == "high")
    }

    /// All five the composer offers, one by one, because the two lists agreeing today is not the
    /// same as them being pinned to each other. These five are also exactly what the CLI's own
    /// parser names in its warning message, read out of the binary and confirmed by running it.
    @Test(
        "every level the composer offers is a level the CLI accepts",
        arguments: ["low", "medium", "high", "xhigh", "max"]
    )
    func everyComposerEffort(level: String) {
        let session = Session(workspaceID: "w", effort: level)

        #expect(value(of: "--effort", in: AgentRunner.argv(session: session, resume: nil)) == level)
    }

    /// Effort is an open set, exactly like the model: a repository's settings file can pin one
    /// Bloom has no name for, which is why `ComposerOption.adding` exists. Passing it through is
    /// deliberate. The CLI warns and falls back to its default with exit 0, so an exotic value
    /// costs a line on stderr, while filtering here would silently substitute a level the
    /// repository asked for with one it did not.
    @Test("an effort Bloom does not recognise is still passed through")
    func unknownEffort() {
        let session = Session(workspaceID: "w", effort: "ultracode")

        #expect(value(of: "--effort", in: AgentRunner.argv(session: session, resume: nil)) == "ultracode")
    }

    /// A session row from before the column meant anything, or one a settings file blanked.
    /// `--effort` with nothing after it would make the CLI eat whatever came next.
    @Test("an empty effort sends no flag at all rather than an empty one")
    func emptyEffort() {
        for blank in ["", "   "] {
            let argv = AgentRunner.argv(session: Session(workspaceID: "w", effort: blank), resume: nil)

            #expect(!argv.contains("--effort"), "a blank effort still sent the flag")
        }
    }

    // MARK: Fast mode

    /// "Fast mode trades some reasoning for a quicker reply", which on this CLI is
    /// `--thinking disabled`. Off means the flag is absent rather than set to something else:
    /// sending `adaptive` explicitly would override whatever the session would otherwise pick.
    @Test("fast mode is off unless it is on, and off sends nothing")
    func fastModeOff() {
        let argv = AgentRunner.argv(session: Session(workspaceID: "w"), resume: nil, isFastMode: false)

        #expect(!argv.contains("--thinking"))
    }

    @Test("fast mode turns thinking off")
    func fastModeOn() {
        let argv = AgentRunner.argv(session: Session(workspaceID: "w"), resume: nil, isFastMode: true)

        #expect(value(of: "--thinking", in: argv) == "disabled")
        // Strict where --effort is forgiving: a value outside these three exits 1 before the turn
        // starts, so the only thing Bloom may ever send here is a literal.
        #expect(["enabled", "adaptive", "disabled"].contains(value(of: "--thinking", in: argv) ?? ""))
    }

    /// This used to pin two copies of the same string together, one in the core and one in the
    /// composer's footer, because the two modules could not see each other. `ComposerControls` is
    /// in the core now and there is only one copy left, so what is left to hold is the string
    /// itself: it is written into the user's database and changing it silently turns every toggle
    /// anybody has ever set back off.
    @Test("the fast mode key is the one already in the database")
    func fastModeKeyIsStable() {
        #expect(ComposerControls.fastModeKey(sessionID: "abc") == "session.abc.fastMode")
    }

    // MARK: Output style

    /// The picker that started this: Claude Code gained output styles, and Bloom offers them in
    /// the composer beside the model and the effort.
    ///
    /// There is **no flag**. Checked against the installed CLI (2.1.238) rather than assumed:
    /// `--help` has no `--output-style`, the binary carries an `outputStyle` settings key described
    /// as "Controls the output style for assistant responses", and `--settings <file-or-json>`
    /// takes a JSON string on the command line. So the only way to state one for a single run,
    /// without writing to a file the user owns, is the object below.
    @Test("the output style the user picked reaches the CLI")
    func passesOutputStyle() {
        let argv = AgentRunner.argv(
            session: Session(workspaceID: "w"), resume: nil, outputStyle: "Concise"
        )

        #expect(value(of: "--settings", in: argv) == #"{"outputStyle":"Concise"}"#)
    }

    /// All four the CLI compiles in, one by one, because the two lists agreeing today is not the
    /// same as them being pinned to each other. These four and their descriptions were read out of
    /// the binary, and `OutputStyle.builtIns` is the copy the menu draws.
    @Test(
        "every built in style the composer offers reaches the CLI by name",
        arguments: ["Proactive", "Concise", "Explanatory", "Learning"]
    )
    func everyBuiltInOutputStyle(name: String) {
        let argv = AgentRunner.argv(
            session: Session(workspaceID: "w"), resume: nil, outputStyle: name
        )

        #expect(value(of: "--settings", in: argv) == #"{"outputStyle":"\#(name)"}"#)
        #expect(OutputStyle.builtIns.contains { $0.name == name })
    }

    /// The default adds nothing at all, which is the whole of the reason it is not sent as a word.
    ///
    /// `default` is a real value the CLI understands, so sending it would work. It would also be a
    /// stated setting, and `--settings` outranks a `.claude/settings.json` in the repository. A
    /// picker left alone must not quietly switch off a style the project chose for itself.
    @Test(
        "the default output style sends no settings at all",
        arguments: [String?](["", "   ", "default", nil])
    )
    func defaultOutputStyleSendsNothing(name: String?) {
        let argv = AgentRunner.argv(
            session: Session(workspaceID: "w"), resume: nil, outputStyle: name
        )

        #expect(!argv.contains("--settings"), "the default still sent a settings object")
    }

    /// A style is named by a file somebody else wrote, so the name is not Bloom's to trust. Built
    /// rather than interpolated: a quote in a name would otherwise close the object early and the
    /// CLI would read the remains as a path, which is what it does with anything it cannot parse.
    /// It exits 1 with "Settings file not found", before the turn starts.
    @Test("a custom style name is encoded rather than pasted in")
    func encodesCustomOutputStyle() throws {
        let argv = AgentRunner.argv(
            session: Session(workspaceID: "w"), resume: nil, outputStyle: #"Say "hi""#
        )
        let settings = try #require(value(of: "--settings", in: argv))
        let object = try JSONSerialization.jsonObject(with: Data(settings.utf8)) as? [String: String]

        #expect(object == ["outputStyle": #"Say "hi""#])
    }

    /// `--settings` takes one value and a second occurrence replaces the first rather than merging
    /// with it, so nothing else may reach for the flag. This is what would catch a second setting
    /// being added as its own flag instead of another key in this object.
    @Test("the settings object is passed once and holds only what Bloom states")
    func settingsFlagIsUsedOnce() {
        let argv = AgentRunner.argv(
            session: Session(workspaceID: "w", effort: "max"),
            resume: "abc",
            isFastMode: true,
            outputStyle: "Explanatory"
        )

        #expect(argv.filter { $0 == "--settings" }.count == 1)
    }

    /// The same, for the same reason. Both keys are in the user's database already.
    @Test("the output style key is the one already in the database")
    func outputStyleKeyIsStable() {
        #expect(ComposerControls.outputStyleKey(sessionID: "abc") == "session.abc.outputStyle")
    }

    /// A flag left dangling at the end silently eats whatever the CLI reads next, or nothing.
    @Test("no flag is left without its value")
    func noDanglingFlags() {
        let argv = AgentRunner.argv(
            session: Session(workspaceID: "w", effort: "max"),
            resume: "abc",
            isFastMode: true,
            outputStyle: "Concise"
        )
        let valueless: Set<String> = ["--verbose", "--include-partial-messages"]

        for (index, item) in argv.enumerated() where item.hasPrefix("--") && !valueless.contains(item) {
            #expect(argv.indices.contains(index + 1), "\(item) has nothing after it")
            #expect(!argv[index + 1].hasPrefix("--"), "\(item) is followed by another flag")
        }
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
        // The context size is deliberately NOT taken from here; see the test below.
        #expect(reloaded.contextTokens == 0)
        #expect(reloaded.state == .idle)

        // A second turn accumulates rather than replacing.
        await runner.ingest(try #require(AgentEvent.decode(line: resultLine)))
        #expect(try await store.session(id: session.id)?.outputTokens == 720)

        let stored = try await store.messages(sessionID: session.id)
        #expect(stored.map(\.durationMS) == [7880, 7880])
    }

    @Test("records the context the model had, not the turn's total")
    func recordsContextWindowUsage() async throws {
        let store = try makeTestStore("agent")
        let session = try await makeSession(store)
        let runner = AgentRunner(workspacePath: "/tmp/w", session: session, store: store)

        for event in try fixtureSessionLines().compactMap({ AgentEvent.decode(line: $0) }) {
            await runner.ingest(event)
        }

        let reloaded = try #require(try await store.session(id: session.id))
        // The last assistant event's own call: 2 input, 215 created, 38_137 read. That is what the
        // model was handed.
        #expect(reloaded.contextTokens == 2 + 215 + 38_137)
        // And emphatically not the usage on the result line, which sums every API call the turn
        // made. On a real session that read 619k against a 1M window where 60k was in front of the
        // model, which is the whole reason this is tracked as the turn runs.
        #expect(reloaded.contextTokens != 6 + 100_420 + 13_928)
    }

    @Test("marks the session failed when the result says so")
    func failsOnErrorResult() async throws {
        let store = try makeTestStore("agent")
        let session = try await makeSession(store)
        // Mid turn, because a result belongs to one. `send` is what applies `turnStarted` in the
        // app and it needs a real process, so the fixture states the same thing directly:
        // `SessionLifecycle` ignores a result on a session with no turn open, which is what stops
        // a late result reopening a turn the process exit has already filed.
        let runner = AgentRunner(
            workspacePath: "/tmp/w", session: session.with { $0.apply(.turnStarted) }, store: store
        )

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

    /// The whole loop, from the row the composer's picker writes to the argv of a real spawn.
    ///
    /// The unit tests above pin the array `argv` builds; this pins that the runner actually reads
    /// the setting and hands it over. A picker that writes a row nothing reads is the bug this
    /// suite exists for, and it has happened once already with `--effort`.
    @Test("the stored output style reaches the process the runner spawns")
    func spawnsWithTheStoredOutputStyle() async throws {
        let store = try makeTestStore("agent")
        let session = try await makeSession(store)
        try await store.setSetting(ComposerControls.outputStyleKey(sessionID: session.id), "Concise")

        let recorder = ProcessRecorder()
        let runner = AgentRunner(
            workspacePath: "/tmp/w", session: session, store: store, makeProcess: recorder.factory
        )

        try await runner.send("hello")

        let process = try #require(recorder.last)
        let index = try #require(process.launch.arguments.firstIndex(of: "--settings"))
        #expect(process.launch.arguments[index + 1] == #"{"outputStyle":"Concise"}"#)
    }

    /// The other half, and the one that matters more: a session nobody has set a style on spawns
    /// with no settings object at all, so a style the repository chose in its own
    /// `.claude/settings.json` is left standing.
    @Test("a session with no output style spawns without a settings object")
    func spawnsWithoutSettingsByDefault() async throws {
        let store = try makeTestStore("agent")
        let session = try await makeSession(store)
        let recorder = ProcessRecorder()
        let runner = AgentRunner(
            workspacePath: "/tmp/w", session: session, store: store, makeProcess: recorder.factory
        )

        try await runner.send("hello")

        let process = try #require(recorder.last)
        #expect(!process.launch.arguments.contains("--settings"))
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


// MARK: - Permission asks

/// Answering the CLI's permission question, and answering it on the user's behalf.
///
/// The behaviour under test is the part with real consequences: a question that arrives becomes a
/// session nobody would call "running", a rule granted days ago answers without troubling anyone
/// and says so, and nothing is ever left hanging against a closed pipe.
@Suite("AgentRunner permissions", .tags(.agentProtocol, .persistence), .scratchDirectory)
struct AgentRunnerPermissionTests {
    /// The captured `can_use_tool` line, with a request id of the caller's choosing so one test
    /// can raise two different questions.
    private func askLine(id: String = "req-1", toolUse: String = "toolu_01") -> String {
        PermissionAskTests.realAsk
            .replacingOccurrences(of: "2f9899b1-849f-4d1b-b4b2-9c6e1304b300", with: id)
            .replacingOccurrences(of: "toolu_01AtAvbhP1XGtDNmpbSCSBRf", with: toolUse)
    }

    private func ask(id: String = "req-1", toolUse: String = "toolu_01") -> PermissionAsk {
        guard case .permissionAsk(let ask) = AgentEvent.decode(line: askLine(id: id, toolUse: toolUse))! else {
            fatalError("the fixture stopped being a permission ask")
        }
        return ask
    }

    private func repoID(of session: Session, in store: Store) async throws -> RepoID {
        try #require(await store.workspace(id: session.workspaceID)).repoID
    }

    /// A runner with a live fake process behind it, so answers have somewhere to be written.
    private func running(
        _ store: Store,
        session: Session
    ) async throws -> (runner: AgentRunner, process: FakeProcess) {
        let recorder = ProcessRecorder()
        let runner = AgentRunner(
            workspacePath: "/tmp/w", session: session, store: store, makeProcess: recorder.factory
        )
        try await runner.send("go")
        let process = try #require(recorder.last)
        return (runner, process)
    }

    /// What the runner wrote back to the CLI, decoded.
    private func answers(on process: FakeProcess) -> [JSONValue] {
        process.stdin
            .compactMap(JSONValue.parse)
            .filter { $0["type"]?.stringValue == "control_response" }
    }

    // MARK: Arriving

    @Test("a question makes the session waiting, which is not running")
    func waiting() async throws {
        let store = try makeTestStore("perm")
        let session = try await makeSession(store)
        let (runner, _) = try await running(store, session: session)

        await runner.ingest(.permissionAsk(ask()))

        #expect(await runner.currentSession.state == .waiting)
        let stored = try #require(await store.session(id: session.id))
        #expect(stored.state == .waiting)
        // And it is the one thing in the app that is alive and doing nothing.
        #expect(stored.state != .running)
    }

    @Test("the question is on the pile and in the transcript")
    func recorded() async throws {
        let store = try makeTestStore("perm")
        let session = try await makeSession(store)
        let (runner, _) = try await running(store, session: session)

        await runner.ingest(.permissionAsk(ask()))

        #expect(await runner.pendingAsks.map(\.requestID) == ["req-1"])
        #expect(try await store.pendingPermissionAsks(sessionID: session.id).count == 1)

        // A row where the call would have been, filed under the call it is about.
        let rows = try await store.messages(sessionID: session.id)
        let row = try #require(rows.last { $0.kind == .permissionAsk })
        #expect(row.refID == "toolu_01")
    }

    // MARK: Answering

    @Test("allowing writes an answer the CLI can act on and lets the turn run again")
    func allowing() async throws {
        let store = try makeTestStore("perm")
        let session = try await makeSession(store)
        let (runner, process) = try await running(store, session: session)
        await runner.ingest(.permissionAsk(ask()))

        await runner.answer(requestID: "req-1", decision: .allow(scope: .once))

        let answer = try #require(answers(on: process).first)
        #expect(answer["response"]?["request_id"]?.stringValue == "req-1")
        #expect(answer["response"]?["response"]?["behavior"]?.stringValue == "allow")

        #expect(await runner.pendingAsks.isEmpty)
        #expect(await runner.currentSession.state == .running)
        #expect(try await store.pendingPermissionAsks(sessionID: session.id).isEmpty)
        #expect(try await store.permissionAskDecisions(sessionID: session.id)["req-1"] == "allow-once")
    }

    @Test("denying carries the sentence the user typed")
    func denying() async throws {
        let store = try makeTestStore("perm")
        let session = try await makeSession(store)
        let (runner, process) = try await running(store, session: session)
        await runner.ingest(.permissionAsk(ask()))

        await runner.answer(requestID: "req-1", decision: .deny(message: "Not on my machine.", endsTurn: false))

        let answer = try #require(answers(on: process).first)
        #expect(answer["response"]?["response"]?["behavior"]?.stringValue == "deny")
        #expect(answer["response"]?["response"]?["message"]?.stringValue == "Not on my machine.")
        #expect(try await store.permissionAskDecisions(sessionID: session.id)["req-1"] == "deny")
    }

    /// Two answers racing one question must not both reach the pipe: the CLI would log the second
    /// as a mismatch, and the user would have answered twice.
    @Test("a question can only be answered once")
    func answeredOnce() async throws {
        let store = try makeTestStore("perm")
        let session = try await makeSession(store)
        let (runner, process) = try await running(store, session: session)
        await runner.ingest(.permissionAsk(ask()))

        await runner.answer(requestID: "req-1", decision: .allow(scope: .once))
        await runner.answer(requestID: "req-1", decision: .deny(message: "no", endsTurn: false))

        #expect(answers(on: process).count == 1)
    }

    /// Two questions at once is ordinary, and the session only goes back to running when the last
    /// of them has been dealt with.
    @Test("the session keeps waiting while any question is unanswered")
    func severalAtOnce() async throws {
        let store = try makeTestStore("perm")
        let session = try await makeSession(store)
        let (runner, _) = try await running(store, session: session)

        await runner.ingest(.permissionAsk(ask(id: "req-1", toolUse: "toolu_01")))
        await runner.ingest(.permissionAsk(ask(id: "req-2", toolUse: "toolu_02")))

        await runner.answer(requestID: "req-1", decision: .allow(scope: .once))
        #expect(await runner.currentSession.state == .waiting)

        await runner.answer(requestID: "req-2", decision: .allow(scope: .once))
        #expect(await runner.currentSession.state == .running)
    }

    // MARK: Granting, and being answered by a grant

    @Test("always allow records a rule that outlives the session")
    func grantsAProjectRule() async throws {
        let store = try makeTestStore("perm")
        let session = try await makeSession(store)
        let (runner, _) = try await running(store, session: session)
        await runner.ingest(.permissionAsk(ask()))

        await runner.answer(requestID: "req-1", decision: .allow(scope: .project))

        let grants = try await store.permissionGrants(repoID: try await repoID(of: session, in: store))
        #expect(grants.map(\.displayText) == ["Bash(sudo -n true)"])
        // What the ask was about, so the revocation list can say what was being looked at.
        #expect(grants.first?.grantedFor == "sudo -n true")
    }

    @Test("allowing once grants nothing")
    func onceGrantsNothing() async throws {
        let store = try makeTestStore("perm")
        let session = try await makeSession(store)
        let (runner, _) = try await running(store, session: session)
        await runner.ingest(.permissionAsk(ask()))

        await runner.answer(requestID: "req-1", decision: .allow(scope: .once))

        #expect(try await store.permissionGrants().isEmpty)
    }

    /// The whole point of the rule model: the second time the same question comes round, nobody is
    /// asked. The session never enters `waiting`, so nothing anywhere lights up.
    @Test("a rule granted earlier answers without anybody being asked")
    func autoAllowed() async throws {
        let store = try makeTestStore("perm")
        let session = try await makeSession(store)
        try await store.upsert(PermissionGrant.granting(
            PermissionRule(toolName: "Bash", ruleContent: "sudo -n true"),
            repoID: try await repoID(of: session, in: store)
        ))
        let (runner, process) = try await running(store, session: session)

        await runner.ingest(.permissionAsk(ask()))

        #expect(answers(on: process).count == 1)
        #expect(await runner.pendingAsks.isEmpty)
        #expect(await runner.currentSession.state != .waiting)
        #expect(try await store.pendingPermissionAsks(sessionID: session.id).isEmpty)
    }

    /// A call that ran because of a decision made days ago must not look like a call that simply
    /// ran, or nobody can judge whether to take the rule back.
    @Test("an auto-allowed call says which rule allowed it")
    func autoAllowIsVisible() async throws {
        let store = try makeTestStore("perm")
        let session = try await makeSession(store)
        try await store.upsert(PermissionGrant.granting(
            PermissionRule(toolName: "Bash", ruleContent: "sudo -n true"),
            repoID: try await repoID(of: session, in: store)
        ))
        let recorder = ProcessRecorder()
        let runner = AgentRunner(
            workspacePath: "/tmp/w", session: session, store: store, makeProcess: recorder.factory
        )
        try await runner.send("go")

        let events = runner.events
        let watching = Task<String?, Never> {
            for await event in events {
                if case .permissionDecided(let resolution) = event { return resolution.note }
            }
            return nil
        }
        await runner.ingest(.permissionAsk(ask()))
        let note = await watching.value

        #expect(note?.contains("Bash(sudo -n true)") == true)
        #expect(try await store.permissionAskDecisions(sessionID: session.id)["req-1"]
            == PermissionAskOutcome.auto)
    }

    /// Order matters and it is not obvious. A stored rule answers a question in the same breath
    /// it arrives, so `.permissionDecided` can overtake the `.permissionAsk` it decides. A view
    /// that gets them that way round has no row to settle, drops the decision, and draws an
    /// answered question with four live buttons under it. This was found by running the real CLI,
    /// not by reading the code.
    @Test("the question always reaches a view before the answer to it does")
    func askArrivesBeforeItsDecision() async throws {
        let store = try makeTestStore("perm")
        let session = try await makeSession(store)
        try await store.upsert(PermissionGrant.granting(
            PermissionRule(toolName: "Bash", ruleContent: "sudo -n true"),
            repoID: try await repoID(of: session, in: store)
        ))
        let recorder = ProcessRecorder()
        let runner = AgentRunner(
            workspacePath: "/tmp/w", session: session, store: store, makeProcess: recorder.factory
        )
        try await runner.send("go")

        let events = runner.events
        let watching = Task<[String], Never> {
            var seen: [String] = []
            for await event in events {
                switch event {
                case .permissionAsk: seen.append("ask")
                case .permissionDecided:
                    seen.append("decided")
                    return seen
                default: break
                }
            }
            return seen
        }
        await runner.ingest(.permissionAsk(ask()))

        #expect(await watching.value == ["ask", "decided"])
    }

    /// A person can answer while the grant lookup is still in flight, because the question is on
    /// screen before the lookup finishes. Whoever gets there first wins and the other does
    /// nothing: two `control_response` lines for one request id makes the CLI log a mismatch and
    /// discard one of them.
    @Test("a person answering during the rule lookup is not overtaken by it")
    func answerRacesTheLookup() async throws {
        let store = try makeTestStore("perm")
        let session = try await makeSession(store)
        try await store.upsert(PermissionGrant.granting(
            PermissionRule(toolName: "Bash", ruleContent: "sudo -n true"),
            repoID: try await repoID(of: session, in: store)
        ))
        let (runner, process) = try await running(store, session: session)

        // Both routes, started together. Exactly one of them may reach the pipe.
        async let arriving: Void = runner.ingest(.permissionAsk(ask()))
        async let answering: Void = runner.answer(requestID: "req-1", decision: .deny(message: "no", endsTurn: false))
        _ = await (arriving, answering)

        #expect(answers(on: process).count == 1)
        #expect(await runner.pendingAsks.isEmpty)
        // And the session is not left claiming to be waiting for a settled question.
        #expect(await runner.currentSession.state != .waiting)
    }

    @Test("using a rule is counted, so the list can say whether it earns its place")
    func countsUses() async throws {
        let store = try makeTestStore("perm")
        let session = try await makeSession(store)
        let repo = try await repoID(of: session, in: store)
        try await store.upsert(PermissionGrant.granting(
            PermissionRule(toolName: "Bash", ruleContent: "sudo -n true"), repoID: repo
        ))
        let (runner, _) = try await running(store, session: session)

        await runner.ingest(.permissionAsk(ask(id: "req-1", toolUse: "toolu_01")))
        await runner.ingest(.permissionAsk(ask(id: "req-2", toolUse: "toolu_02")))

        #expect(try await store.permissionGrants(repoID: repo).first?.useCount == 2)
    }

    /// Revoking has to bite on the next question, not on the next launch. Nothing caches the
    /// grants, which is what makes that true.
    @Test("a revoked rule stops answering immediately")
    func revocationBites() async throws {
        let store = try makeTestStore("perm")
        let session = try await makeSession(store)
        let repo = try await repoID(of: session, in: store)
        let grant = try await store.upsert(PermissionGrant.granting(
            PermissionRule(toolName: "Bash", ruleContent: "sudo -n true"), repoID: repo
        ))
        let (runner, _) = try await running(store, session: session)

        await runner.ingest(.permissionAsk(ask(id: "req-1", toolUse: "toolu_01")))
        #expect(await runner.currentSession.state != .waiting)

        try await store.deletePermissionGrant(id: grant.id)
        await runner.ingest(.permissionAsk(ask(id: "req-2", toolUse: "toolu_02")))

        #expect(await runner.currentSession.state == .waiting)
        #expect(await runner.pendingAsks.map(\.requestID) == ["req-2"])
    }

    /// A grant belongs to a project. Another project's grant is not an answer here, which is the
    /// property that makes keying them by repository worth anything.
    @Test("another project's rule does not answer this one")
    func grantsDoNotLeakAcrossProjects() async throws {
        let store = try makeTestStore("perm")
        let session = try await makeSession(store)
        let other = try await store.upsert(Repo(name: "other", path: "/tmp/other-\(newID())"))
        try await store.upsert(PermissionGrant.granting(
            PermissionRule(toolName: "Bash", ruleContent: "sudo -n true"), repoID: other.id
        ))
        let (runner, _) = try await running(store, session: session)

        await runner.ingest(.permissionAsk(ask()))

        #expect(await runner.currentSession.state == .waiting)
    }

    // MARK: Stopping and quitting

    /// The difference between a turn that ends and a turn that dies. The CLI holds a blocked turn
    /// open until it gets an answer, an abort, or an EOF, and only the first produces a `result`.
    @Test("stopping denies every open question in words before the pipe closes")
    func stopDenies() async throws {
        let store = try makeTestStore("perm")
        let session = try await makeSession(store)
        let (runner, process) = try await running(store, session: session)
        await runner.ingest(.permissionAsk(ask(id: "req-1", toolUse: "toolu_01")))
        await runner.ingest(.permissionAsk(ask(id: "req-2", toolUse: "toolu_02")))

        await runner.cancel()

        let written = answers(on: process)
        #expect(written.count == 2)
        for answer in written {
            #expect(answer["response"]?["response"]?["behavior"]?.stringValue == "deny")
            // Ends the turn rather than letting it carry on without the call.
            #expect(answer["response"]?["response"]?["interrupt"]?.boolValue == true)
            #expect(answer["response"]?["response"]?["message"]?.stringValue?.isEmpty == false)
        }
    }

    /// Stop from a button, which is the path a person actually takes. `cancelNow` signals the
    /// process synchronously so a busy actor cannot delay it, which means the deny has to be
    /// written before the signal rather than inside the actor work behind it. Against the real CLI
    /// the wrong order hands the model "AbortError: Tool permission stream closed" instead of a
    /// sentence.
    @Test("Stop from a button answers the question before it signals the process")
    func cancelNowDeniesFirst() async throws {
        let store = try makeTestStore("perm")
        let session = try await makeSession(store)
        let (runner, process) = try await running(store, session: session)
        await runner.ingest(.permissionAsk(ask()))

        runner.cancelNow()

        let answer = try #require(answers(on: process).first)
        #expect(answer["response"]?["response"]?["behavior"]?.stringValue == "deny")
        #expect(answer["response"]?["response"]?["message"]?.stringValue
            == PermissionDecision.stoppedMessage)
        // Written while the pipe was still open, which is the whole point.
        #expect(process.wasTerminated)
    }

    @Test("quitting denies in words too, and says it was Bloom that did it")
    func quitDenies() async throws {
        let store = try makeTestStore("perm")
        let session = try await makeSession(store)
        let (runner, process) = try await running(store, session: session)
        await runner.ingest(.permissionAsk(ask()))

        runner.denyPendingAsks(PermissionDecision.quittingMessage)

        let answer = try #require(answers(on: process).first)
        #expect(answer["response"]?["response"]?["message"]?.stringValue
            == PermissionDecision.quittingMessage)
        #expect(await runner.pendingAsks.isEmpty)
    }

    /// Draining is one step so a Stop racing a quit cannot answer the same question twice.
    @Test("denying twice on the way out writes one answer per question")
    func denyingIsIdempotent() async throws {
        let store = try makeTestStore("perm")
        let session = try await makeSession(store)
        let (runner, process) = try await running(store, session: session)
        await runner.ingest(.permissionAsk(ask()))

        runner.denyPendingAsks(PermissionDecision.quittingMessage)
        runner.denyPendingAsks(PermissionDecision.quittingMessage)

        #expect(answers(on: process).count == 1)
    }
}
