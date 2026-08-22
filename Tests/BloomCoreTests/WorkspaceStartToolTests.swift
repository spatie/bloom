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
        var failure: (any Error)?

        func tool() -> WorkspaceStartTool {
            WorkspaceStartTool { [self] order, identity in
                orders.append(order)
                identities.append(identity)
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
