import Foundation
import Testing
@testable import BloomCore

/// The workspace bridge, end to end, through the real `claude` binary.
///
/// This is the one thing no hermetic test can stand in for. `BridgeServerTests` proves the socket,
/// `BridgeShimTests` proves the relay binary, and neither says anything about **registration**,
/// which is the half most likely to be wrong: whether `--mcp-config` pointed at a file Bloom wrote
/// actually makes the CLI launch the shim, list its tools and let the model call one. There is no
/// free way to ask. `claude mcp list` rejects `--mcp-config` ("error: unknown option"), so it is a
/// top-level session flag only and every check of it costs a turn.
///
///     BLOOM_LIVE=1 ./Tools/test-core.sh LiveBridge
///
/// Deliberately the cheapest turn that can prove it: haiku, one sentence, one tool call.
private let liveEnabled = ProcessInfo.processInfo.environment["BLOOM_LIVE"] == "1"
private let shimPath = BridgeRegistration.shimPath()

@Suite("LiveBridge", .enabled(if: liveEnabled && shimPath != nil), .tags(.subprocess), .scratchDirectory)
struct LiveBridgeTests {
    @Test("a real agent lists the bridge's tools and calls one", .timeLimit(.minutes(5)))
    func callsWhoami() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }

        let store = try makeTestStore("live-bridge")
        // The repository itself is the worktree here. Cutting a real one would prove nothing this
        // test is about and would cost seconds of git on every run.
        let project = try await store.upsert(Repo(name: "billing", path: repo.path, defaultBranch: "main"))
        let workspace = try await store.upsert(Workspace(
            repoID: project.id,
            name: "cut the invoice index",
            branch: "bloom/cut-the-invoice-index",
            path: repo.path,
            baseBranch: "main",
            origin: .agent(parentWorkspaceID: WorkspaceID("parent-1"), spawnToolUseID: "toolu_live")
        ))
        let session = try await store.upsert(Session(
            workspaceID: workspace.id,
            model: "haiku",
            permissionMode: .acceptEdits
        ))

        let server = try BridgeServer(store: store)
        try server.start()
        defer { server.stop() }

        let handle = try #require(server.register(session: session, workspace: workspace))
        #expect(handle.attachment.role == .child)
        let configPath = try #require(handle.mcpConfigPath)

        let runner = AgentRunner(
            workspacePath: repo.path,
            session: session,
            store: store,
            mcpConfigPath: configPath
        )
        // Exactly the argv the app builds, printed so a failing run says what was actually sent.
        let arguments = await runner.launch().arguments
        #expect(arguments.contains("--mcp-config"))
        #expect(!arguments.contains("--strict-mcp-config"))

        let log = LiveBridgeLog()
        let pump = Task { for await event in runner.events { log.record(event) } }
        defer { pump.cancel() }

        // An MCP call may be a permission question, and there is nobody watching a test. Answering
        // it here also measures whether one is asked at all, which decides what a child in Ask
        // mode can do without the owner.
        let answered = Answered()
        let approvals = Task {
            while !Task.isCancelled {
                for ask in (try? await store.pendingPermissionAsks()) ?? [] where ask.sessionID == session.id {
                    answered.record(ask.ask.toolName)
                    await runner.answer(requestID: ask.requestID, decision: .allow(scope: .once))
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { approvals.cancel() }

        try await runner.send("""
            Call the whoami tool from the bloom-workspace-bridge MCP server. \
            Reply with only the workspace name it reports and nothing else.
            """)

        await waitUntil("the turn finished", within: .seconds(180)) { log.sawResult }

        // What the CLI itself said it had, off `system/init`. This is the registration answering:
        // the tool is in the list because the config file was read, the shim was launched, and the
        // handshake completed. Nothing else in the suite can see this.
        print("LiveBridge: bridge tools offered: \(log.bridgeTools)")
        print("LiveBridge: mcp_servers on init: \(log.mcpServersLine)")
        print("LiveBridge: tools called: \(log.calledTools)")
        print("LiveBridge: permission asks: \(answered.toolNames)")
        print("LiveBridge: reply: \(log.resultSummary)")

        // The name the model sees, measured rather than guessed: the CLI carries the server name
        // through with its hyphens intact rather than sanitising them to underscores.
        #expect(log.bridgeTools == ["mcp__\(BridgeRegistration.serverName)__whoami"])
        #expect(log.calledTools.contains { $0.contains("whoami") })
        // The user's own MCP servers are still there, which is what not passing
        // `--strict-mcp-config` buys and the reason it must never be passed here.
        #expect(log.mcpServersLine.contains(BridgeRegistration.serverName))
        #expect(log.sawResult)
        #expect(log.resultSummary.lowercased().contains("cut the invoice index"))

        let stored = try await store.session(id: session.id)
        print("LiveBridge: cost $\(stored?.costUSD ?? 0)")
    }
}

/// What a live run said about the bridge, which is more than the shared `EventLog` collects.
final class LiveBridgeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var initTools: [String] = []
    private var servers = ""
    private var called: [String] = []
    private var result: String?

    var bridgeTools: [String] {
        lock.lock(); defer { lock.unlock() }
        return initTools.filter { $0.lowercased().contains("bloom") }
    }

    var mcpServersLine: String {
        lock.lock(); defer { lock.unlock() }
        return servers
    }

    var calledTools: [String] {
        lock.lock(); defer { lock.unlock() }
        return called
    }

    var sawResult: Bool {
        lock.lock(); defer { lock.unlock() }
        return result != nil
    }

    var resultSummary: String {
        lock.lock(); defer { lock.unlock() }
        return result ?? ""
    }

    func record(_ event: AgentEvent) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .initialized(let start):
            initTools = start.tools
            if let raw = try? JSONDecoder().decode(JSONValue.self, from: start.raw),
               let list = raw["mcp_servers"],
               let data = try? JSONEncoder().encode(list) {
                servers = String(decoding: data, as: UTF8.self)
            }
        case .toolUse(let use):
            called.append(use.name)
        case .result(let outcome):
            result = outcome.summary
        default:
            break
        }
    }
}

/// What the agent was asked permission for, if anything.
final class Answered: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []

    var toolNames: [String] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }

    func record(_ subject: String) {
        lock.lock(); defer { lock.unlock() }
        if !seen.contains(subject) { seen.append(subject) }
    }
}
