import Foundation
import Testing
@testable import BloomCore

/// `workspace_start`: an agent asking Bloom for another workspace.
///
/// The executor is a stub here, and deliberately. What the app does with an order is the app's,
/// on the main actor, and the test target cannot reach it; what this suite pins is everything
/// between the wire and that hand-off, which is where every refusal lives.
@Suite("workspace_start", .tags(.persistence), .scratchDirectory)
struct WorkspaceStartToolTests {
    /// Records what the tool asked for, so a test can assert on the order rather than on prose.
    private final class Recorder: @unchecked Sendable {
        var orders: [AgentWorkspaceOrder] = []
        var identities: [BridgeIdentity] = []
        var spawnIDs: [String] = []
        var failure: (any Error)?

        func tool() -> WorkspaceStartTool {
            WorkspaceStartTool { [self] order, identity, spawnID in
                orders.append(order)
                identities.append(identity)
                spawnIDs.append(spawnID)
                if let failure { throw failure }
                return StartedWorkspaceSummary(
                    workspaceID: WorkspaceID(rawValue: "w-new"),
                    name: order.name ?? "Named by Bloom",
                    branch: "claude/named-by-bloom",
                    path: "/tmp/worktrees/w-new"
                )
            }
        }
    }

    private struct Fixture {
        let store: Store
        let identity: BridgeIdentity
        let workspace: Workspace
    }

    private func fixture(origin: WorkspaceOrigin = .user, label: String = "start") async throws -> Fixture {
        let store = try makeTestStore(label)
        let repo = try await store.upsert(Repo(name: "flare", path: "/tmp/flare", defaultBranch: "main"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id,
            name: "group occurrences",
            branch: "claude/group-occurrences",
            path: "/tmp/flare-group",
            baseBranch: "main",
            origin: origin
        ))
        let session = try await store.upsert(Session(workspaceID: workspace.id, title: "First chat"))

        return Fixture(
            store: store,
            identity: BridgeIdentity(
                sessionID: session.id,
                workspaceID: workspace.id,
                role: BridgeRole(origin: origin)
            ),
            workspace: workspace
        )
    }

    private func request(_ arguments: [String: JSONValue]) -> MCPRequest {
        MCPRequest(id: .number(1), method: "workspace_start", params: .object(arguments))
    }

    // MARK: Who may call it

    @Test("only a parent can see it, so a child never has a tool it cannot use")
    func roleGate() {
        let tool = Recorder().tool()

        #expect(tool.roles == [.parent])
        #expect(BridgeToolbox(handlers: [tool]).tools(for: .child).isEmpty)
        #expect(BridgeToolbox(handlers: [tool]).tools(for: .parent).map(\.name) == ["workspace_start"])
    }

    /// The role gate already hides it. This is the second lock, for something speaking raw MCP at
    /// the socket with a child's token: one level of nesting is the limit.
    @Test("a workspace started by an agent is refused even when it calls directly")
    func noGrandchildren() async throws {
        let fixture = try await self.fixture(
            origin: .agent(parentWorkspaceID: WorkspaceID(rawValue: "w-parent"), spawnToolUseID: "t1"),
            label: "start-child"
        )
        let recorder = Recorder()

        let result = await recorder.tool().call(
            request(["prompt": .string("do a thing")]), as: fixture.identity, store: fixture.store
        )

        #expect(result.isError)
        #expect(result.text.contains("itself started by an agent"))
        #expect(recorder.orders.isEmpty)
    }

    // MARK: What it accepts

    @Test("a prompt is all it needs, and the order carries who asked")
    func startsWithAPrompt() async throws {
        let fixture = try await fixture()
        let recorder = Recorder()

        let result = await recorder.tool().call(
            request(["prompt": .string("Port the importer to the new API")]),
            as: fixture.identity,
            store: fixture.store
        )

        #expect(!result.isError)
        #expect(recorder.orders.count == 1)
        #expect(recorder.orders[0].prompt == "Port the importer to the new API")
        #expect(recorder.identities[0].workspaceID == fixture.workspace.id)
    }

    @Test("the optional arguments travel, and blank ones do not")
    func optionalArguments() async throws {
        let fixture = try await fixture()
        let recorder = Recorder()

        _ = await recorder.tool().call(
            request([
                "prompt": .string("do a thing"),
                "name": .string("Sentry importer"),
                "base_branch": .string("develop"),
                "agent": .string("codex"),
            ]),
            as: fixture.identity,
            store: fixture.store
        )

        let order = try #require(recorder.orders.first)
        #expect(order.name == "Sentry importer")
        #expect(order.baseBranch == "develop")
        #expect(order.agent == .codex)

        _ = await recorder.tool().call(
            request(["prompt": .string("do a thing"), "name": .string("   ")]),
            as: fixture.identity,
            store: fixture.store
        )

        #expect(recorder.orders[1].name == nil)
    }

    @Test("no agent named means the caller's own, decided by the app rather than guessed here")
    func agentDefaultsToTheCallers() async throws {
        let fixture = try await fixture()
        let recorder = Recorder()

        _ = await recorder.tool().call(
            request(["prompt": .string("do a thing")]), as: fixture.identity, store: fixture.store
        )

        #expect(recorder.orders[0].agent == nil)
    }

    // MARK: What it refuses

    @Test("a missing or empty prompt is refused before anything is created")
    func promptIsRequired() async throws {
        let fixture = try await fixture()
        let recorder = Recorder()

        for arguments in [[:], ["prompt": JSONValue.string("   ")]] {
            let result = await recorder.tool().call(
                request(arguments), as: fixture.identity, store: fixture.store
            )
            #expect(result.isError)
        }

        #expect(recorder.orders.isEmpty)
    }

    /// Cursor and OpenCode are in `AgentKind` and have no runner, so a workspace on either would
    /// exist and never start. Refusing names the two that work rather than silently choosing.
    @Test("an agent Bloom cannot run is refused, and the refusal says which ones it can")
    func unrunnableAgent() async throws {
        let fixture = try await fixture()
        let recorder = Recorder()

        let result = await recorder.tool().call(
            request(["prompt": .string("do a thing"), "agent": .string("cursor")]),
            as: fixture.identity,
            store: fixture.store
        )

        #expect(result.isError)
        #expect(result.text.contains("claudeCode"))
        #expect(result.text.contains("codex"))
        #expect(recorder.orders.isEmpty)
    }

    @Test("a caller whose workspace has been archived away is told so rather than crashing")
    func callerIsGone() async throws {
        let fixture = try await fixture()
        let recorder = Recorder()

        let result = await recorder.tool().call(
            request(["prompt": .string("do a thing")]),
            as: BridgeIdentity(
                sessionID: fixture.identity.sessionID,
                workspaceID: WorkspaceID(rawValue: "w-vanished"),
                role: .parent
            ),
            store: fixture.store
        )

        #expect(result.isError)
        #expect(result.text.contains("no longer in Bloom's database"))
    }

    /// An agent that misreads its own instructions can ask in a loop, and each one is a real
    /// worktree, a real process and real spend.
    @Test("a caller that already has the limit running is refused")
    func limit() async throws {
        let fixture = try await fixture()
        let recorder = Recorder()

        for index in 0..<WorkspaceStartTool.maximumChildren {
            _ = try await fixture.store.upsert(Workspace(
                repoID: fixture.workspace.repoID,
                name: "child \(index)",
                branch: "claude/child-\(index)",
                path: "/tmp/child-\(index)",
                baseBranch: "main",
                origin: .agent(parentWorkspaceID: fixture.workspace.id, spawnToolUseID: "t\(index)")
            ))
        }

        let result = await recorder.tool().call(
            request(["prompt": .string("one more")]), as: fixture.identity, store: fixture.store
        )

        #expect(result.isError)
        #expect(result.text.contains("limit"))
        #expect(recorder.orders.isEmpty)
    }

    @Test("archived children do not count against the limit, because the limit is on what runs")
    func archivedChildrenDoNotCount() async throws {
        let fixture = try await fixture()
        let recorder = Recorder()

        for index in 0..<WorkspaceStartTool.maximumChildren {
            var child = Workspace(
                repoID: fixture.workspace.repoID,
                name: "child \(index)",
                branch: "claude/child-\(index)",
                path: "/tmp/child-\(index)",
                baseBranch: "main",
                origin: .agent(parentWorkspaceID: fixture.workspace.id, spawnToolUseID: "t\(index)")
            )
            child.state = .archived
            _ = try await fixture.store.upsert(child)
        }

        let result = await recorder.tool().call(
            request(["prompt": .string("one more")]), as: fixture.identity, store: fixture.store
        )

        #expect(!result.isError)
    }

    // MARK: What it answers

    /// The call returns when the workspace exists, not when its work is done. The answer has to
    /// say so, or a model reads a success as a finished job and reports it as one.
    @Test("the answer names the workspace and says the work has not happened yet")
    func answerDoesNotClaimCompletion() async throws {
        let fixture = try await fixture()
        let recorder = Recorder()

        let result = await recorder.tool().call(
            request(["prompt": .string("do a thing"), "name": .string("Sentry importer")]),
            as: fixture.identity,
            store: fixture.store
        )

        #expect(!result.isError)
        #expect(result.text.contains("w-new"))
        #expect(result.text.contains("Sentry importer"))
        #expect(result.text.contains("starting"))
        #expect(result.text.contains("cannot wait for it"))
    }

    @Test("a failure to start is told to the model rather than to the transport")
    func startFailureIsAResult() async throws {
        let fixture = try await fixture()
        let recorder = Recorder()
        recorder.failure = AgentRunnerError.previousRunStillExiting

        let result = await recorder.tool().call(
            request(["prompt": .string("do a thing")]), as: fixture.identity, store: fixture.store
        )

        #expect(result.isError)
        #expect(result.text.contains("could not start"))
    }

    /// The tool's own half of the diagnosis: it reads the caller's project so a failed start can
    /// be explained, and it answers with the explanation rather than with git's argv.
    @Test("a start that failed in a repository with no commits says so through the tool")
    func startFailureIsDiagnosed() async throws {
        let repoPath = TestScratch.unique("bloom-git")
        try FileManager.default.createDirectory(atPath: repoPath, withIntermediateDirectories: true)
        try await Shell.check("git", ["init", "-q", "-b", "main"], cwd: repoPath)

        let store = try makeTestStore("diagnosed")
        let repo = try await store.upsert(Repo(name: "flare", path: repoPath, defaultBranch: "main"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id,
            name: "group occurrences",
            branch: "claude/group-occurrences",
            path: repoPath,
            baseBranch: "main"
        ))
        let session = try await store.upsert(Session(workspaceID: workspace.id, title: "First chat"))

        let recorder = Recorder()
        recorder.failure = ShellError(
            command: "git worktree add -b do-thing -- \(repoPath)/do-thing main",
            status: 128,
            stderr: "fatal: invalid reference: main"
        )

        let result = await recorder.tool().call(
            request(["prompt": .string("do a thing")]),
            as: BridgeIdentity(sessionID: session.id, workspaceID: workspace.id, role: .parent),
            store: store
        )

        #expect(result.isError)
        #expect(result.text.contains("'flare' has no commits yet"))
        #expect(!result.text.contains("invalid reference"))
        #expect(!result.text.contains("worktree add"))
    }

    /// The description is the only thing the model reads before deciding, so the three facts it
    /// must not get wrong are pinned here: it does not block, the child has no context, and it
    /// costs money.
    @Test("the description tells the model the three things it would otherwise assume")
    func descriptionSaysWhatMatters() {
        let description = Recorder().tool().tool.description

        #expect(description.contains("not when its work is done"))
        #expect(description.contains("cannot see this conversation"))
        #expect(description.contains("real money"))
        #expect(!description.lowercased().contains("subagent"))
    }
}

/// The spawn id, which exists so a retried call does not cut a second worktree.
///
/// It was a fresh UUID, which meant two identical calls produced two ids and the dedup the column
/// was added for could not happen. MCP does not carry the model's own tool-use id to the server,
/// so the id is a digest of the call instead: it repeats exactly when the call repeats.
@Suite("workspace_start: not twice", .tags(.persistence), .scratchDirectory)
struct WorkspaceStartDedupTests {
    /// A count a `@Sendable` closure may raise. The suite is serial, so no lock is needed and one
    /// would only obscure what is being counted.
    private final class Counter: @unchecked Sendable {
        private(set) var value = 0
        func bump() { value += 1 }
    }

    private func order(prompt: String = "Import the webhooks", name: String? = nil) -> AgentWorkspaceOrder {
        AgentWorkspaceOrder(prompt: prompt, name: name)
    }

    private let parent = WorkspaceID(rawValue: "w-parent")

    @Test("the same call names itself the same way twice")
    func stableAcrossCalls() {
        #expect(order().spawnID(parentWorkspaceID: parent) == order().spawnID(parentWorkspaceID: parent))
    }

    @Test("a different call, or a different parent, is a different spawn")
    func differsWhereItShould() {
        let base = order().spawnID(parentWorkspaceID: parent)

        #expect(order(prompt: "Something else").spawnID(parentWorkspaceID: parent) != base)
        #expect(order(name: "Named").spawnID(parentWorkspaceID: parent) != base)
        #expect(order().spawnID(parentWorkspaceID: WorkspaceID(rawValue: "w-other")) != base)
    }

    @Test("it is short enough to read in a log")
    func shortEnough() {
        let id = order().spawnID(parentWorkspaceID: parent)

        #expect(id.count == 16)
        #expect(id.filter(\.isHexDigit).count == id.count)
    }

    @Test("a repeat of a call answers with the workspace the first one made, and cuts nothing")
    func repeatIsRecognised() async throws {
        let store = try makeTestStore("start-dedup")
        let repo = try await store.upsert(Repo(name: "flare", path: "/tmp/flare", defaultBranch: "main"))
        let caller = try await store.upsert(Workspace(
            repoID: repo.id, name: "parent", branch: "main-work", path: "/tmp/parent",
            baseBranch: "main", origin: .user
        ))
        let session = try await store.upsert(Session(workspaceID: caller.id, title: "chat"))
        let identity = BridgeIdentity(sessionID: session.id, workspaceID: caller.id, role: .parent)

        let starts = Counter()
        let tool = WorkspaceStartTool { _, identity, spawnID in
            starts.bump()
            _ = try await store.upsert(Workspace(
                repoID: repo.id,
                name: "the child",
                branch: "claude/the-child",
                path: "/tmp/child",
                baseBranch: "main",
                origin: .agent(parentWorkspaceID: identity.workspaceID, spawnToolUseID: spawnID)
            ))
            return StartedWorkspaceSummary(
                workspaceID: WorkspaceID(rawValue: "w-child"), name: "the child",
                branch: "claude/the-child", path: "/tmp/child"
            )
        }

        let request = MCPRequest(
            id: .number(1), method: "workspace_start",
            params: .object(["prompt": .string("Import the webhooks")])
        )

        let first = await tool.call(request, as: identity, store: store)
        let second = await tool.call(request, as: identity, store: store)

        #expect(!first.isError)
        #expect(!second.isError)
        #expect(starts.value == 1)
        #expect(second.text.contains("already_started"))
        #expect(second.text.contains("Nothing new was created"))
    }
}

/// Bloom answering permission questions about its own tools.
///
/// Measured on a live run: the first `workspace_start` in a project stopped the parent's turn on
/// an ask, and with nobody watching the turn sat waiting and died cancelled on quit, having
/// started nothing. See `BridgeToolApproval` for why answering it is not a shortcut round consent.
@Suite("Bloom's own tools")
struct BridgeToolApprovalTests {
    @Test("Bloom answers for the tools it wrote")
    func ownToolsAreApproved() {
        #expect(BridgeToolApproval.isSelfApproved(toolName: "mcp__bloom-workspace-bridge__whoami"))
        #expect(BridgeToolApproval.isSelfApproved(toolName: "mcp__bloom-workspace-bridge__workspace_start"))
    }

    /// The tools the agent brings with it reach outside anything Bloom knows about. Nothing here
    /// touches them, and this is the assertion that says so.
    @Test("it answers for nothing else, whoever is asking")
    func everythingElseStillAsks() {
        for name in ["Bash", "Write", "Edit", "WebFetch", "mcp__figma__create_new_file"] {
            #expect(!BridgeToolApproval.isSelfApproved(toolName: name))
        }
    }

    /// A server whose name merely starts the same way is not ours, and a tool of ours reached
    /// under somebody else's server name is not ours either.
    @Test("a lookalike server name is not Bloom")
    func lookalikesAreRefused() {
        #expect(!BridgeToolApproval.isSelfApproved(toolName: "mcp__bloom-workspace-bridge-evil__workspace_start"))
        #expect(!BridgeToolApproval.isSelfApproved(toolName: "mcp__other__workspace_start"))
        #expect(!BridgeToolApproval.isSelfApproved(toolName: "workspace_start"))
    }

    /// Opting a tool in is a decision someone makes about that tool, not something it inherits by
    /// being served from the same socket.
    @Test("a tool of ours that is not on the list still asks")
    func newToolsAreNotAutomaticallyIn() {
        #expect(!BridgeToolApproval.isSelfApproved(toolName: "mcp__bloom-workspace-bridge__workspace_archive"))
    }

    @Test("the prefix follows the server's name rather than repeating it")
    func prefixIsComposed() {
        #expect(BridgeToolApproval.toolPrefix == "mcp__\(BridgeRegistration.serverName)__")
    }

    @Test("the transcript is told who let it through")
    func theNoteSaysWhy() {
        #expect(BridgeToolApproval.note.contains("Bloom's own tool"))
    }
}
