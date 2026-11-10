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
        private let defaultPreferences = WorkspaceStartPreferences(
            defaults: UserDefaults(suiteName: "WorkspaceStartToolTests.\(UUID().uuidString)")!
        )
        var orders: [AgentWorkspaceOrder] = []
        var identities: [BridgeIdentity] = []
        var projects: [Repo] = []
        var origins: [WorkspaceOrigin] = []
        var failure: (any Error)?
        var terminalChat = false

        /// The spawn keys the tool actually decided, read back off the origins it handed over. The
        /// tool used to be given one whoever called it; now only a caller that is itself a
        /// workspace produces one, so the origin is where the answer lives.
        var spawnIDs: [String] { origins.compactMap(\.spawnToolUseID) }

        func tool(preferences: WorkspaceStartPreferences? = nil) -> WorkspaceStartTool {
            WorkspaceStartTool(preferences: preferences ?? defaultPreferences) { [self] order, project, identity, origin in
                try await record(order, project: project, identity: identity, origin: origin)
            }
        }

        func record(
            _ order: AgentWorkspaceOrder,
            project: Repo,
            identity: BridgeIdentity,
            origin: WorkspaceOrigin
        ) async throws -> StartedWorkspaceSummary {
            orders.append(order)
            identities.append(identity)
            projects.append(project)
            origins.append(origin)
            if let failure { throw failure }
            return StartedWorkspaceSummary(
                workspaceID: WorkspaceID(rawValue: "w-new"),
                name: order.name ?? "Named by Bloom",
                branch: "claude/named-by-bloom",
                path: "/tmp/worktrees/w-new",
                terminalChat: terminalChat
            )
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
                role: .workspace
            ),
            workspace: workspace
        )
    }

    private func request(_ arguments: [String: JSONValue]) -> MCPRequest {
        MCPRequest(id: .number(1), method: "workspace_start", params: .object(arguments))
    }

    // MARK: Who may call it

    @Test("terminal_chat reaches both workspace and owner starts", arguments: [true, false])
    func terminalChoice(terminal: Bool) async throws {
        let fixture = try await fixture()
        for identity in [fixture.identity, .owner] {
            let recorder = Recorder()
            let result = await recorder.tool().call(request([
                "project": .string("flare"), "prompt": .string("Inspect this project"),
                "terminal_chat": .bool(terminal),
            ]), as: identity, store: fixture.store)

            #expect(!result.isError)
            #expect(recorder.orders.first?.terminalChat == terminal)
        }
    }

    @Test("omitting terminal_chat or passing null defers to the app preference")
    func defaultTerminalChoice() async throws {
        let fixture = try await fixture()
        let recorder = Recorder()
        for value in [nil, JSONValue.null] {
            var arguments: [String: JSONValue] = ["prompt": .string("Inspect this project")]
            arguments["terminal_chat"] = value
            let result = await recorder.tool().call(request(arguments), as: fixture.identity, store: fixture.store)
            #expect(!result.isError)
            #expect(recorder.orders.last?.terminalChat == nil)
        }
    }

    @Test("terminal_chat refuses non-boolean values", arguments: [JSONValue.string("true"), .number(1), .object([:])])
    func invalidTerminalChoice(value: JSONValue) async throws {
        let fixture = try await fixture()
        let recorder = Recorder()
        let result = await recorder.tool().call(request([
            "prompt": .string("Inspect this project"), "terminal_chat": value,
        ]), as: fixture.identity, store: fixture.store)

        #expect(result.isError)
        #expect(result.text.contains("'terminal_chat' must be true or false"))
        #expect(recorder.orders.isEmpty)
    }

    @Test("CLI starts do not register an unreachable completion watch")
    func cliDoesNotWatch() async throws {
        let fixture = try await fixture()
        let recorder = Recorder()
        recorder.terminalChat = true
        let result = await recorder.tool().call(request([
            "prompt": .string("Inspect this project"), "notify_when_done": .bool(true),
        ]), as: fixture.identity, store: fixture.store)

        #expect(!result.isError)
        let answer = try #require(JSONValue.parse(result.text))
        #expect(answer["notify_when_done"]?.boolValue == false)
        #expect(result.text.contains("cannot report completion of a CLI chat"))
        let fields = try #require(answer.objectValue)
        #expect(Set(fields.keys) == [
            "workspace_id", "name", "branch", "path", "state", "notify_when_done", "note",
        ])
        let watches = try await fixture.store.unspentWorkspaceDoneWatches(targetWorkspaceID: WorkspaceID("w-new"))
        #expect(watches.isEmpty)
    }

    @Test("workspace starts resolve the app preference and explicit choices for each agent",
          arguments: AgentKind.allCases, [true, false])
    func terminalStartMode(agent: AgentKind, appDefault: Bool) {
        let expected = WorkspaceStartMode.chat(usesCLI: true, agent: agent)
        #expect(AgentWorkspaceOrder(prompt: "Task").startMode(defaultTerminalChat: appDefault, agent: agent)
            == (appDefault ? expected : .chat))
        #expect(AgentWorkspaceOrder(prompt: "Task", terminalChat: true)
            .startMode(defaultTerminalChat: appDefault, agent: agent) == expected)
        #expect(AgentWorkspaceOrder(prompt: "Task", terminalChat: false)
            .startMode(defaultTerminalChat: appDefault, agent: agent) == .chat)
    }

    @Test("CLI workspace tasks are opening arguments, including quotes and newlines",
          arguments: [AgentKind.claudeCode, .codex])
    func cliOpeningArgument(agent: AgentKind) throws {
        let prompt = "Inspect 'quoted' input\nDo not expand $(anything) or `commands`."
        let order = AgentWorkspaceOrder(prompt: prompt, agent: agent, terminalChat: true)
        let mode = order.startMode(defaultTerminalChat: false, agent: agent)
        let cli = try #require(mode.cliAgentKind)
        let arguments = try #require(cli.interactiveArguments(
            prompt: order.prompt, sessionID: SessionID("capture"), model: "", effort: ""
        ))
        #expect(Array(arguments.suffix(2)) == ["--", prompt])
    }

    @Test("every workspace agent and the owner see it")
    func roleGate() {
        let tool = Recorder().tool()

        #expect(tool.roles == [.workspace, .owner])
        #expect(BridgeToolbox(handlers: [tool]).tools(for: .workspace).map(\.name) == ["workspace_start"])
        #expect(BridgeToolbox(handlers: [tool]).tools(for: .owner).map(\.name) == ["workspace_start"])
    }

    /// No role hides the tool from a workspace an agent started any more, so this refusal is the
    /// only lock on nesting, and it is the one that stops a runaway agent cutting worktrees
    /// without end. One level is the limit.
    @Test("a workspace started by an agent sees the tool and is refused when it calls")
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
                "model": .string("gpt-5.6-sol"),
                "effort": .string("medium"),
            ]),
            as: fixture.identity,
            store: fixture.store
        )

        let order = try #require(recorder.orders.first)
        #expect(order.name == "Sentry importer")
        #expect(order.baseBranch == "develop")
        #expect(order.agent == .codex)
        #expect(order.model == "gpt-5.6-sol")
        #expect(order.effort == "medium")

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

    // MARK: Which branch it starts on

    /// A caller, a store and a repository that really has the branches, because everything on this
    /// path is decided by asking git what is there.
    private func gitFixture(label: String) async throws -> (fixture: Fixture, repo: TempRepo) {
        let repo = try await TempRepo()
        try await Shell.check("git", ["branch", "freek/figma"], cwd: repo.path)

        let store = try makeTestStore(label)
        let project = try await store.upsert(
            Repo(name: "flare", path: repo.path, defaultBranch: "main")
        )
        let workspace = try await store.upsert(Workspace(
            repoID: project.id,
            name: "group occurrences",
            branch: "claude/group-occurrences",
            path: "/tmp/flare-group",
            baseBranch: "main"
        ))
        let session = try await store.upsert(Session(workspaceID: workspace.id, title: "First chat"))

        return (
            Fixture(
                store: store,
                identity: BridgeIdentity(
                    sessionID: session.id, workspaceID: workspace.id, role: .workspace
                ),
                workspace: workspace
            ),
            repo
        )
    }

    /// The whole point of the second route. Cutting a fresh branch off a colleague's branch gives a
    /// worktree identical to it, so the Changes tab draws nothing and the workspace is useless for
    /// the job it was started for. What has to reach the app is a `WorkspaceCheckout`.
    @Test("a call naming an existing branch starts on that branch", .tags(.git, .subprocess))
    func startsOnAnExistingBranch() async throws {
        let (fixture, repo) = try await gitFixture(label: "start-existing")
        defer { repo.cleanUp() }
        let recorder = Recorder()

        let result = await recorder.tool().call(
            request([
                "prompt": .string("Read what is on this branch and fix the failing test"),
                "existing_branch": .string("freek/figma"),
            ]),
            as: fixture.identity,
            store: fixture.store
        )

        #expect(!result.isError)
        let order = try #require(recorder.orders.first)
        #expect(order.source.tab == .existingBranch)
        #expect(order.source.checkout == .branch(ExistingBranch(name: "freek/figma", isLocal: true)))
        #expect(order.source.baseBranch == nil)
    }

    @Test("a call naming a pull request preserves the pull request checkout")
    func startsOnAPullRequest() async throws {
        let fixture = try await fixture(label: "start-pull-request")
        let recorder = Recorder()
        let pullRequest = PullRequestListing(
            number: 66,
            title: "Add name suffix",
            headRefName: "name-suffix",
            baseRefName: "main"
        )
        let tool = WorkspaceStartTool(
            start: { order, project, identity, origin in
                try await recorder.record(
                    order, project: project, identity: identity, origin: origin
                )
            },
            resolvePullRequest: { reference, path in
                #expect(reference == "#66")
                #expect(path == "/tmp/flare")
                return .checkout(.pullRequest(pullRequest))
            }
        )

        let result = await tool.call(
            request([
                "prompt": .string("Review the existing pull request"),
                "pull_request": .string("#66"),
            ]),
            as: fixture.identity,
            store: fixture.store
        )

        #expect(!result.isError)
        #expect(recorder.orders.first?.source == .pullRequest(pullRequest))
    }

    @Test("a call naming neither still cuts a new branch, as it always did", .tags(.git, .subprocess))
    func defaultsToANewBranch() async throws {
        let (fixture, repo) = try await gitFixture(label: "start-default")
        defer { repo.cleanUp() }
        let recorder = Recorder()

        _ = await recorder.tool().call(
            request(["prompt": .string("do a thing")]), as: fixture.identity, store: fixture.store
        )

        let order = try #require(recorder.orders.first)
        #expect(order.source == .newBranch(from: nil))
        #expect(order.source.checkout == nil)
    }

    /// The refusal the caller cannot get from a picker it cannot see. Told this, it asks again with
    /// a name that is there; told nothing, it gets a workspace on a branch nobody meant.
    @Test("a branch that is not in the project is refused, with what is", .tags(.git, .subprocess))
    func refusesABranchThatIsNotThere() async throws {
        let (fixture, repo) = try await gitFixture(label: "start-missing-branch")
        defer { repo.cleanUp() }
        let recorder = Recorder()

        let result = await recorder.tool().call(
            request([
                "prompt": .string("do a thing"),
                "existing_branch": .string("freek/figmaa"),
            ]),
            as: fixture.identity,
            store: fixture.store
        )

        #expect(result.isError)
        #expect(result.text.contains("no branch called 'freek/figmaa'"))
        #expect(result.text.contains("'freek/figma'"))
        #expect(recorder.orders.isEmpty)
    }

    /// Git allows one worktree per branch, and the project's own checkout is a worktree. Refused in
    /// words here rather than by git exiting 128 half way through a start.
    @Test("the branch the project itself is on is refused, by its path", .tags(.git, .subprocess))
    func refusesTheProjectsOwnBranch() async throws {
        let (fixture, repo) = try await gitFixture(label: "start-held-branch")
        defer { repo.cleanUp() }
        let recorder = Recorder()

        let result = await recorder.tool().call(
            request(["prompt": .string("do a thing"), "existing_branch": .string("main")]),
            as: fixture.identity,
            store: fixture.store
        )

        #expect(result.isError)
        #expect(result.text.contains("the project itself is on"))
        #expect(result.text.contains("base_branch"))
        #expect(recorder.orders.isEmpty)
    }

    @Test("naming both branch arguments is refused before anything is looked up")
    func refusesBothBranchArguments() async throws {
        let fixture = try await fixture()
        let recorder = Recorder()

        let result = await recorder.tool().call(
            request([
                "prompt": .string("do a thing"),
                "base_branch": .string("main"),
                "existing_branch": .string("freek/figma"),
            ]),
            as: fixture.identity,
            store: fixture.store
        )

        #expect(result.isError)
        #expect(result.text.contains("base_branch"))
        #expect(result.text.contains("existing_branch"))
        #expect(recorder.orders.isEmpty)
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
                sessionID: fixture.identity.sessionID ?? SessionID(rawValue: "s-gone"),
                workspaceID: WorkspaceID(rawValue: "w-vanished"),
                role: .workspace
            ),
            store: fixture.store
        )

        #expect(result.isError)
        #expect(result.text.contains("no longer in Bloom's database"))
    }

    // MARK: Another project

    /// The call this was written for: an agent in the site's project handing work to a new
    /// workspace in the app's. The workspace goes where it was sent, and it is still the caller's
    /// child in every way the brakes read.
    @Test("a named project from inside a workspace starts it there, and it is still the caller's child")
    func startsInAnotherProject() async throws {
        let fixture = try await fixture(label: "start-elsewhere")
        let other = try await fixture.store.upsert(
            Repo(name: "bloom", path: "/tmp/bloom", defaultBranch: "main")
        )
        let recorder = Recorder()

        let result = await recorder.tool().call(
            request(["prompt": .string("Fix the importer"), "project": .string("bloom")]),
            as: fixture.identity,
            store: fixture.store
        )

        #expect(!result.isError)
        #expect(recorder.projects.map(\.id) == [other.id])
        #expect(recorder.origins.first?.parentWorkspaceID == fixture.workspace.id)
        #expect(recorder.origins.first?.isAgentSpawned == true)
        #expect(
            recorder.spawnIDs
                == [
                    AgentWorkspaceOrder(prompt: "Fix the importer")
                        .spawnID(parentWorkspaceID: fixture.workspace.id, otherProject: other.id),
                ]
        )
    }

    /// Resolved the owner's client's way, so the refusal is the same sentence too, and a name
    /// that matches nothing is never read as "here".
    @Test("a project Bloom does not have is refused from inside a workspace, and nothing starts")
    func refusesAnUnknownProject() async throws {
        let fixture = try await fixture(label: "start-elsewhere-unknown")
        let recorder = Recorder()

        let result = await recorder.tool().call(
            request(["prompt": .string("Fix the importer"), "project": .string("nowhere")]),
            as: fixture.identity,
            store: fixture.store
        )

        #expect(result.isError)
        #expect(result.text.contains("no project called 'nowhere'"))
        #expect(result.text.contains("'flare'"))
        #expect(recorder.orders.isEmpty)
    }

    @Test("two projects answering to one name are refused with their paths")
    func refusesAnAmbiguousProject() async throws {
        let fixture = try await fixture(label: "start-elsewhere-ambiguous")
        _ = try await fixture.store.upsert(Repo(name: "bloom", path: "/tmp/one/bloom", defaultBranch: "main"))
        _ = try await fixture.store.upsert(Repo(name: "bloom", path: "/tmp/two/bloom", defaultBranch: "main"))
        let recorder = Recorder()

        let result = await recorder.tool().call(
            request(["prompt": .string("Fix the importer"), "project": .string("bloom")]),
            as: fixture.identity,
            store: fixture.store
        )

        #expect(result.isError)
        #expect(result.text.contains("/tmp/one/bloom"))
        #expect(recorder.orders.isEmpty)
    }

    /// Leaving it out is what every call made before this could, and its key must not move, or a
    /// retry that straddles an upgrade would cut a second worktree.
    @Test("leaving the project out still starts in the caller's own, under the same key as before")
    func omittedProjectIsUnchanged() async throws {
        let fixture = try await fixture(label: "start-elsewhere-omitted")
        _ = try await fixture.store.upsert(Repo(name: "bloom", path: "/tmp/bloom", defaultBranch: "main"))
        let recorder = Recorder()

        let result = await recorder.tool().call(
            request(["prompt": .string("Fix the importer")]),
            as: fixture.identity,
            store: fixture.store
        )

        #expect(!result.isError)
        #expect(recorder.projects.map(\.id) == [fixture.workspace.repoID])
        #expect(
            recorder.spawnIDs
                == [AgentWorkspaceOrder(prompt: "Fix the importer").spawnID(parentWorkspaceID: fixture.workspace.id)]
        )
    }

    /// Naming the project the caller is already in is the same ask as naming none, so a retry
    /// that adds or drops the argument is still recognised as the same call.
    @Test("naming the caller's own project is the same call as naming none")
    func namingItsOwnProjectIsTheSameCall() async throws {
        let fixture = try await fixture(label: "start-elsewhere-own")
        let recorder = Recorder()

        _ = await recorder.tool().call(
            request(["prompt": .string("Fix the importer")]), as: fixture.identity, store: fixture.store
        )
        _ = await recorder.tool().call(
            request(["prompt": .string("Fix the importer"), "project": .string("flare")]),
            as: fixture.identity,
            store: fixture.store
        )

        #expect(recorder.projects.map(\.id) == [fixture.workspace.repoID, fixture.workspace.repoID])
        #expect(recorder.spawnIDs.count == 2)
        #expect(Set(recorder.spawnIDs).count == 1)
    }

    /// Sending the work elsewhere is not a way round the nesting limit.
    @Test("a workspace an agent started is refused even when it names another project")
    func noGrandchildrenElsewhere() async throws {
        let fixture = try await self.fixture(
            origin: .agent(parentWorkspaceID: WorkspaceID(rawValue: "w-parent"), spawnToolUseID: "t1"),
            label: "start-elsewhere-child"
        )
        _ = try await fixture.store.upsert(Repo(name: "bloom", path: "/tmp/bloom", defaultBranch: "main"))
        let recorder = Recorder()

        let result = await recorder.tool().call(
            request(["prompt": .string("do a thing"), "project": .string("bloom")]),
            as: fixture.identity,
            store: fixture.store
        )

        #expect(result.isError)
        #expect(result.text.contains("itself started by an agent"))
        #expect(recorder.orders.isEmpty)
    }

    /// The ceiling is on the parent, not on a project, so children it started elsewhere count.
    @Test("children running in another project count against the caller's ceiling")
    func childrenElsewhereCount() async throws {
        let fixture = try await fixture(label: "start-elsewhere-limit")
        let other = try await fixture.store.upsert(
            Repo(name: "bloom", path: "/tmp/bloom", defaultBranch: "main")
        )
        for index in 0..<WorkspaceStartAllowance.maximumChildren {
            _ = try await fixture.store.upsert(Workspace(
                repoID: other.id,
                name: "child \(index)",
                branch: "claude/child-\(index)",
                path: "/tmp/elsewhere-\(index)",
                baseBranch: "main",
                origin: .agent(parentWorkspaceID: fixture.workspace.id, spawnToolUseID: "t\(index)")
            ))
        }
        let recorder = Recorder()

        let result = await recorder.tool().call(
            request(["prompt": .string("one more")]), as: fixture.identity, store: fixture.store
        )

        #expect(result.isError)
        #expect(result.text.contains("limit"))
        #expect(recorder.orders.isEmpty)
    }

    /// An agent that misreads its own instructions can ask in a loop, and each one is a real
    /// worktree, a real process and real spend.
    @Test("a caller that already has the limit running is refused")
    func limit() async throws {
        let fixture = try await fixture()
        let recorder = Recorder()

        for index in 0..<WorkspaceStartAllowance.maximumChildren {
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

    @Test("workspace_start uses the configured running limit")
    func configuredLimit() async throws {
        let fixture = try await fixture(label: "start-configured-limit")
        let domain = "WorkspaceStartToolTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = WorkspaceStartPreferences(defaults: defaults)
        preferences.maximumChildren = 3
        let recorder = Recorder()
        let tool = recorder.tool(preferences: preferences)

        for index in 0..<2 {
            _ = try await fixture.store.upsert(Workspace(
                repoID: fixture.workspace.repoID,
                name: "child \(index)",
                branch: "claude/child-\(index)",
                path: "/tmp/configured-child-\(index)",
                baseBranch: "main",
                origin: .agent(parentWorkspaceID: fixture.workspace.id, spawnToolUseID: "t\(index)")
            ))
        }

        let allowed = await tool.call(
            request(["prompt": .string("one more")]), as: fixture.identity, store: fixture.store
        )
        #expect(!allowed.isError)
        #expect(recorder.orders.count == 1)

        _ = try await fixture.store.upsert(Workspace(
            repoID: fixture.workspace.repoID,
            name: "child 2",
            branch: "claude/child-2",
            path: "/tmp/configured-child-2",
            baseBranch: "main",
            origin: .agent(parentWorkspaceID: fixture.workspace.id, spawnToolUseID: "t2")
        ))
        let refused = await tool.call(
            request(["prompt": .string("a different task")]),
            as: fixture.identity,
            store: fixture.store
        )
        #expect(refused.isError)
        #expect(refused.text.contains("limit"))
        #expect(recorder.orders.count == 1)

        preferences.maximumChildren = 4
        let afterChange = await tool.call(
            request(["prompt": .string("a different task")]),
            as: fixture.identity,
            store: fixture.store
        )
        #expect(!afterChange.isError)
        #expect(recorder.orders.count == 2)
    }

    /// The bug the two brakes had while they were checked in two places. The owner's rate was
    /// asked after the dedup, with a comment saying a retry of a call that already cut a worktree
    /// is not another start, and the parent's ceiling was asked before it, so a parent that was
    /// full had its retries answered with a limit instead of with the workspace it already had.
    @Test("a retry from a caller at its limit gets the workspace it already made, not a refusal")
    func retryAtTheLimitIsNotRefused() async throws {
        let fixture = try await fixture()
        let recorder = Recorder()
        let call = request(["prompt": .string("one more")])

        // The workspace this exact call produced, recorded under the digest a repeat of it makes.
        let order = AgentWorkspaceOrder(prompt: "one more")
        _ = try await fixture.store.upsert(Workspace(
            repoID: fixture.workspace.repoID,
            name: "the first answer",
            branch: "claude/one-more",
            path: "/tmp/one-more",
            baseBranch: "main",
            origin: .agent(
                parentWorkspaceID: fixture.workspace.id,
                spawnToolUseID: order.spawnID(parentWorkspaceID: fixture.workspace.id)
            )
        ))
        // And enough others beside it to put the caller over its ceiling.
        for index in 0..<WorkspaceStartAllowance.maximumChildren {
            _ = try await fixture.store.upsert(Workspace(
                repoID: fixture.workspace.repoID,
                name: "child \(index)",
                branch: "claude/child-\(index)",
                path: "/tmp/child-\(index)",
                baseBranch: "main",
                origin: .agent(parentWorkspaceID: fixture.workspace.id, spawnToolUseID: "t\(index)")
            ))
        }

        let result = await recorder.tool().call(call, as: fixture.identity, store: fixture.store)

        #expect(!result.isError)
        #expect(result.text.contains("already_started"))
        #expect(result.text.contains("the first answer"))
        #expect(recorder.orders.isEmpty)
    }

    @Test("archived children do not count against the limit, because the limit is on what runs")
    func archivedChildrenDoNotCount() async throws {
        let fixture = try await fixture()
        let recorder = Recorder()

        for index in 0..<WorkspaceStartAllowance.maximumChildren {
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
            as: BridgeIdentity(sessionID: session.id, workspaceID: workspace.id, role: .workspace),
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
        let tool = Recorder().tool().tool
        let description = tool.description

        #expect(description.contains("not when its work is done"))
        #expect(description.contains("cannot see this conversation"))
        // The choice, in the sheet's own words, so a model reading the tool list and a person
        // reading the tab strip are told the same thing. See `AgentStartSource`.
        #expect(description.contains(WorkspaceSourceTab.newBranch.title))
        #expect(description.contains(WorkspaceSourceTab.existingBranch.title))
        #expect(description.contains(WorkspaceSourceTab.existingBranch.explanation))
        #expect(description.contains("existing_branch"))
        #expect(description.contains("real money"))
        #expect(tool.inputSchema["properties"]?["effort"] != nil)
        #expect(tool.inputSchema["properties"]?["terminal_chat"]?["type"]?.stringValue == "boolean")
        #expect(description.contains("Open new chats in"))
        #expect(description.contains("workspace_say cannot deliver"))
        #expect(description.contains("notify_when_done does not report"))
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

    @Test("terminal choices distinguish starts and leave the omitted choice's key stable")
    func terminalChoiceInDigest() {
        let implicit = order().spawnID(parentWorkspaceID: parent)
        let terminal = AgentWorkspaceOrder(prompt: "Import the webhooks", terminalChat: true)
        let chat = AgentWorkspaceOrder(prompt: "Import the webhooks", terminalChat: false)

        #expect(terminal.spawnID(parentWorkspaceID: parent) != implicit)
        #expect(chat.spawnID(parentWorkspaceID: parent) != implicit)
        #expect(terminal.spawnID(parentWorkspaceID: parent) != chat.spawnID(parentWorkspaceID: parent))
        #expect(terminal.spawnID(ownerProject: RepoID("r")) != chat.spawnID(ownerProject: RepoID("r")))
    }

    @Test("a different call, or a different parent, is a different spawn")
    func differsWhereItShould() {
        let base = order().spawnID(parentWorkspaceID: parent)

        #expect(order(prompt: "Something else").spawnID(parentWorkspaceID: parent) != base)
        #expect(order(name: "Named").spawnID(parentWorkspaceID: parent) != base)
        #expect(order().spawnID(parentWorkspaceID: WorkspaceID(rawValue: "w-other")) != base)
        #expect(order().spawnID(parentWorkspaceID: parent, otherProject: RepoID("r-bloom")) != base)
        #expect(
            AgentWorkspaceOrder(prompt: "Import the webhooks", model: "gpt-5.6-sol")
                .spawnID(parentWorkspaceID: parent) != base
        )
        #expect(
            AgentWorkspaceOrder(prompt: "Import the webhooks", effort: "medium")
                .spawnID(parentWorkspaceID: parent) != base
        )
    }

    /// The same order from the same parent sent to two projects is two asks. Without the project
    /// in the key, the second would be answered with the first one's workspace.
    @Test("the same call to two other projects is two spawns, and naming none keeps the old key")
    func theProjectIsInTheKey() {
        let bloom = order().spawnID(parentWorkspaceID: parent, otherProject: RepoID("r-bloom"))
        let site = order().spawnID(parentWorkspaceID: parent, otherProject: RepoID("r-site"))

        #expect(bloom != site)
        #expect(bloom == order().spawnID(parentWorkspaceID: parent, otherProject: RepoID("r-bloom")))
        #expect(order().spawnID(parentWorkspaceID: parent, otherProject: nil) == order().spawnID(parentWorkspaceID: parent))
        // Nor can a parent's key for a project collide with the owner's key for the same one.
        #expect(bloom != order().spawnID(ownerProject: RepoID("r-bloom")))
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
        let identity = BridgeIdentity(sessionID: session.id, workspaceID: caller.id, role: .workspace)

        let starts = Counter()
        let tool = WorkspaceStartTool { _, _, _, origin in
            starts.bump()
            _ = try await store.upsert(Workspace(
                repoID: repo.id,
                name: "the child",
                branch: "claude/the-child",
                path: "/tmp/child",
                baseBranch: "main",
                origin: origin
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

    /// The list is what says who let these through, and it is read here rather than at runtime:
    /// a self-approved ask is answered before it is stored, so it leaves no row in the transcript
    /// to carry a note. See `AgentRunner.handle(_:)`.
    @Test("every self-approved name is one of the bridge's own tools")
    func selfApprovedAreOurs() {
        for name in BridgeToolApproval.selfApproved {
            #expect(BridgeToolApproval.isSelfApproved(toolName: BridgeToolApproval.toolPrefix + name))
        }
    }
}
