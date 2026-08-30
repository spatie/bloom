import Foundation
import Testing
@testable import BloomCore

/// The four tools an orchestrator runs a crew with, tested against the store and a stub window.
///
/// The seam is stubbed here and deliberately. What the app does with an order is the app's, on the
/// main actor, and this target cannot reach it; what this suite pins is everything between the
/// wire and that hand-off, which is where every refusal lives and where every decision worth
/// arguing about was made. `agent_list` needs no stub at all, because a crew is rows in `sessions`
/// joined by `parent_session_id` and nothing else.
@Suite("The crew tools", .tags(.persistence), .scratchDirectory)
struct CrewToolTests {
    // MARK: - Support

    private struct Fixture {
        let store: Store
        let workspace: Workspace
        let orchestrator: Session

        var identity: BridgeIdentity {
            BridgeIdentity(sessionID: orchestrator.id, workspaceID: workspace.id, role: .parent)
        }

        func identity(of session: Session) -> BridgeIdentity {
            BridgeIdentity(sessionID: session.id, workspaceID: workspace.id, role: .parent)
        }
    }

    private func fixture(_ label: String) async throws -> Fixture {
        let store = try makeTestStore(label)
        let repo = try await store.upsert(Repo(name: "bloom", path: TestScratch.unique("repo")))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "crew", branch: "bloom/crew",
            path: TestScratch.unique("worktree"), baseBranch: "main"
        ))
        let orchestrator = try await store.upsert(Session(
            workspaceID: workspace.id, title: "Chat"
        ))
        return Fixture(store: store, workspace: workspace, orchestrator: orchestrator)
    }

    @discardableResult
    private func member(
        _ fixture: Fixture,
        _ name: String,
        of parent: Session? = nil,
        state: SessionState = .idle
    ) async throws -> Session {
        try await fixture.store.upsert(Session(
            workspaceID: fixture.workspace.id,
            parentSessionID: (parent ?? fixture.orchestrator).id,
            title: name,
            state: state
        ))
    }

    private func request(
        _ tool: String, _ arguments: [String: JSONValue] = [:]
    ) -> MCPRequest {
        MCPRequest(id: .number(1), method: tool, params: .object(arguments))
    }

    private func answer(_ result: BridgeToolResult) throws -> JSONValue {
        try #require(JSONValue.parse(result.text))
    }

    /// What the window was asked to start, so a test can assert on the order rather than on prose.
    private final class Starts: @unchecked Sendable {
        var orders: [CrewOrder] = []
        var callers: [SessionID] = []
        var workspaces: [WorkspaceID] = []
        var outcome: CrewStartOutcome = .started("Started.")

        func tool() -> AgentStartTool {
            AgentStartTool { [self] order, caller, workspace in
                orders.append(order)
                callers.append(caller)
                workspaces.append(workspace)
                return outcome
            }
        }
    }

    private final class Says: @unchecked Sendable {
        var targets: [String?] = []
        var messages: [String] = []
        var callers: [SessionID] = []
        var outcome: CrewSayOutcome = .delivered("Delivered.")

        func tool() -> AgentSayTool {
            AgentSayTool { [self] target, message, caller, _ in
                targets.append(target)
                messages.append(message)
                callers.append(caller)
                return outcome
            }
        }
    }

    private final class Stops: @unchecked Sendable {
        var names: [String] = []
        var callers: [SessionID] = []
        var outcome: CrewStopOutcome = .stopped("Stopped.")

        func tool() -> AgentStopTool {
            AgentStopTool { [self] name, caller, _ in
                names.append(name)
                callers.append(caller)
                return outcome
            }
        }
    }

    // MARK: - Who may call them

    /// `.parent` and nothing else, four times. A crew member's chat lives in an ordinary
    /// workspace, so its token already carries `.parent` and it comes through the same gate its
    /// orchestrator does: the split between the two is made off the caller's own row, inside each
    /// handler, rather than by a fourth role. Not `.owner`, which is sitting in no workspace and
    /// so has no crew to be talking about, and not `.child`, which reports and that is all.
    @Test("only a workspace agent sees them, and there is no fourth role")
    func roleGate() {
        let toolbox = BridgeToolbox(handlers: [
            Starts().tool(), Says().tool(), AgentListTool(), Stops().tool(),
        ])

        #expect(Starts().tool().roles == [.parent])
        #expect(Says().tool().roles == [.parent])
        #expect(AgentListTool().roles == [.parent])
        #expect(Stops().tool().roles == [.parent])

        #expect(toolbox.tools(for: .parent).map(\.name)
            == ["agent_list", "agent_say", "agent_start", "agent_stop"])
        #expect(toolbox.tools(for: .child).isEmpty)
        #expect(toolbox.tools(for: .owner).isEmpty)
        #expect(toolbox.handler(named: "agent_start", for: .child) == nil)
        #expect(toolbox.handler(named: "agent_say", for: .owner) == nil)
        #expect(BridgeRole.allCases.count == 3)
    }

    /// `agent_list` reads rows and reaches nothing else, so a Bloom with no app behind it serves
    /// it. The other three have to reach the main-actor graph that owns the runners, so they are
    /// bound in `AppModel.bridgeToolbox()` and are not on this list. A copy of that list is a copy
    /// that drifts, which is why the app adds to `.standard` rather than restating it.
    @Test("only the listing is in the standard toolbox")
    func toolboxMembership() {
        let names = BridgeToolbox.standard.tools(for: .parent).map(\.name)

        #expect(names.contains("agent_list"))
        #expect(!names.contains("agent_start"))
        #expect(!names.contains("agent_say"))
        #expect(!names.contains("agent_stop"))
        // It is scoped to the caller's own workspace, so it is no use to a client sitting in none.
        #expect(!BridgeToolbox.standard.tools(for: .owner).map(\.name).contains("agent_list"))
        #expect(BridgeToolbox.standard.tools(for: .child).map(\.name) == ["whoami"])
    }

    /// All four, and they stand or fall together: a crew that can be assembled and not spoken to
    /// is worse than no crew. An orchestrator stopping to ask the owner before it may talk to
    /// agents it started itself is the hung unattended turn `BridgeToolApproval`'s head is about,
    /// with a second bill running at the other end of the unanswered question.
    @Test("Bloom answers its own permission question about all four")
    func selfApproved() {
        for name in ["agent_start", "agent_say", "agent_list", "agent_stop"] {
            #expect(BridgeToolApproval.isSelfApproved(
                toolName: "\(BridgeToolApproval.toolPrefix)\(name)"
            ))
        }

        // The boundary, kept visible from here: what is off the list is what destroys work or
        // publishes, and none of the four does either.
        #expect(!BridgeToolApproval.selfApproved.contains("workspace_merge"))
        #expect(!BridgeToolApproval.selfApproved.contains("quick_prompt_delete"))
        // And the prefix is still the gate: a tool of somebody else's with our name is not ours.
        #expect(!BridgeToolApproval.isSelfApproved(toolName: "agent_start"))
    }

    // MARK: - What the model is told it may pass

    @Test("the schemas say what is required and nothing more")
    func schemas() {
        let start = Starts().tool().tool
        #expect(start.name == "agent_start")
        #expect(start.inputSchema["required"] == .array([.string("name"), .string("task")]))
        let startProperties = start.inputSchema["properties"]
        #expect(startProperties?["model"] != nil)
        #expect(startProperties?["effort"] != nil)
        // No workspace argument anywhere in the family: the token says which worktree is asking,
        // so there is nothing to forge, mistype or hold on to after it has gone stale.
        #expect(startProperties?["workspace"] == nil)

        let say = Says().tool().tool
        #expect(say.inputSchema["required"] == .array([.string("message")]))
        #expect(say.inputSchema["properties"]?["to"] != nil)

        #expect(AgentListTool().tool.inputSchema == BridgeTool.noArguments)

        let stop = Stops().tool().tool
        #expect(stop.inputSchema["required"] == .array([.string("name")]))
    }

    /// The description is the only documentation the model gets, and the one thing it must not be
    /// wrong about is which tool cuts a branch. A crew shares this worktree; a child does not.
    @Test("the descriptions say the crew shares this branch and point at workspace_start")
    func theDescriptionsDrawTheLine() {
        let start = Starts().tool().tool.description
        #expect(start.contains("shares this worktree and this branch"))
        #expect(start.contains("one diff"))
        #expect(start.contains("workspace_start"))
        #expect(start.contains("\(Crew.ceiling)") || start.contains("Three"))

        #expect(AgentListTool().tool.description.contains("shares this branch and these files"))
    }

    /// **A live test lost the whole feature to Claude Code's own Task tool.** Asked to "start a
    /// subagent called reader", the model called Task, because "subagent" is that tool's word and
    /// it was already in its hands. A feature a model never reaches for is invisible, so each of
    /// the four has to say in its description, which is what the model is actually given, what this
    /// one has that a Task subagent does not: a chat of its own that outlives the turn, keeps its
    /// context, can be talked to again, and says when it has stopped.
    @Test("the descriptions tell this apart from the Task tool a model already has")
    func theDescriptionsNameTheTaskTool() {
        let start = Starts().tool().tool.description
        #expect(start.contains("Task tool"))
        #expect(start.contains("its own chat"))
        #expect(start.contains("outlives a single turn"))
        #expect(start.contains("agent_say"))
        // And what to use the Task tool for, because "never use it" is not what is meant.
        #expect(start.contains("one-shot read"))

        #expect(Says().tool().tool.description.contains("Task subagent"))
        #expect(AgentListTool().tool.description.contains("Task subagents are not on this list"))
        #expect(Stops().tool().tool.description.contains("Task subagent"))
    }

    // MARK: - Starting one

    @Test("a start reaches the window with the caller's own session and workspace on it")
    func startHandsOverTheOrder() async throws {
        let fixture = try await self.fixture("crew-start")
        let starts = Starts()

        let result = await starts.tool().call(
            request("agent_start", [
                "name": .string("  tests  "),
                "task": .string("Keep the suite green while I work on the parser."),
                "model": .string("opus"),
                "effort": .string("high"),
            ]),
            as: fixture.identity, store: fixture.store
        )

        #expect(!result.isError)
        #expect(starts.orders.count == 1)
        // Normalised on the way through, by the one function that owns that rule.
        #expect(starts.orders.first?.name == "tests")
        #expect(starts.orders.first?.task == "Keep the suite green while I work on the parser.")
        #expect(starts.orders.first?.model == "opus")
        #expect(starts.orders.first?.effort == "high")
        #expect(starts.callers == [fixture.orchestrator.id])
        #expect(starts.workspaces == [fixture.workspace.id])
    }

    @Test("model and effort left out mean the ones the caller is running on")
    func modelAndEffortAreOptional() async throws {
        let fixture = try await self.fixture("crew-defaults")
        let starts = Starts()

        _ = await starts.tool().call(
            request("agent_start", ["name": .string("tests"), "task": .string("Run them.")]),
            as: fixture.identity, store: fixture.store
        )

        #expect(starts.orders.first?.model == nil)
        #expect(starts.orders.first?.effort == nil)
    }

    /// Depth stays one, and the test is a column rather than a counter: a chat with a
    /// `parentSessionID` is a crew member, and a crew member may not start one. The refusal has to
    /// say what is still open to it, which is asking the agent above it.
    @Test("a subagent cannot start a subagent, and the window is never asked")
    func depthRefusal() async throws {
        let fixture = try await self.fixture("crew-depth")
        let crewMember = try await member(fixture, "tests")
        let starts = Starts()

        let result = await starts.tool().call(
            request("agent_start", ["name": .string("more"), "task": .string("Go.")]),
            as: fixture.identity(of: crewMember), store: fixture.store
        )

        #expect(result.isError)
        #expect(result.text == Crew.sentence(for: .notAnOrchestrator))
        #expect(starts.orders.isEmpty)
    }

    /// Counted from the database rather than from anything held in memory, so a restart cannot
    /// lose the count and it cannot drift from the rows the sidebar draws. It is a check followed
    /// by an act rather than a lock, so two orchestrators in one worktree can still both be let
    /// through; that costs a fourth agent and nothing worse, which is the trade `AgentStartTool`
    /// argues.
    @Test("the ceiling is counted over the running members of the whole workspace")
    func ceilingRefusal() async throws {
        let fixture = try await self.fixture("crew-ceiling")
        try await member(fixture, "one", state: .running)
        try await member(fixture, "two", state: .running)
        try await member(fixture, "three", state: .waiting)
        let starts = Starts()

        let result = await starts.tool().call(
            request("agent_start", ["name": .string("four"), "task": .string("Go.")]),
            as: fixture.identity, store: fixture.store
        )

        #expect(result.isError)
        #expect(result.text == Crew.sentence(for: .tooMany(running: Crew.ceiling)))
        #expect(result.text.contains("agent_stop"))
        #expect(starts.orders.isEmpty)
    }

    /// **`waiting` counts and the two terminal states do not.** A process holding its turn open on
    /// a question is a live agent in the worktree with a bill attached, which is what the ceiling
    /// is about. An agent that died counted as running would hold a third of a workspace's
    /// allowance until the workspace was archived, and three of them would lock the worktree out
    /// of ever starting another with nothing on screen to explain why.
    @Test("a stopped, failed or cancelled member does not hold a slot")
    func theDeadDoNotCount() async throws {
        let fixture = try await self.fixture("crew-census")
        let idle = try await member(fixture, "one", state: .idle)
        let failed = try await member(fixture, "two", state: .failed)
        let cancelled = try await member(fixture, "three", state: .cancelled)
        let running = try await member(fixture, "four", state: .running)

        #expect(!CrewCensus.isRunning(idle))
        #expect(!CrewCensus.isRunning(failed))
        #expect(!CrewCensus.isRunning(cancelled))
        #expect(CrewCensus.isRunning(running))

        let starts = Starts()
        let result = await starts.tool().call(
            request("agent_start", ["name": .string("five"), "task": .string("Go.")]),
            as: fixture.identity, store: fixture.store
        )

        #expect(!result.isError)
        #expect(starts.orders.count == 1)
    }

    /// A stopped agent keeps its conversation and its row until the workspace is archived, so a
    /// second agent taking its name would make the transcript above it read as one agent.
    @Test("a name already in this workspace is refused, running or not")
    func duplicateNameRefusal() async throws {
        let fixture = try await self.fixture("crew-duplicate")
        try await member(fixture, "tests", state: .idle)
        let starts = Starts()

        let result = await starts.tool().call(
            request("agent_start", ["name": .string(" tests "), "task": .string("Go.")]),
            as: fixture.identity, store: fixture.store
        )

        #expect(result.isError)
        #expect(result.text == Crew.sentence(for: .nameTaken("tests")))
        #expect(result.text.contains("agent_say"))
        #expect(starts.orders.isEmpty)
    }

    /// The name is counted across the whole workspace rather than across one chat's crew, because
    /// the sidebar draws them all under one workspace row and two rows reading "tests" is two rows
    /// nobody can address.
    @Test("a name another chat's crew is using in this workspace is taken too")
    func duplicateAcrossChats() async throws {
        let fixture = try await self.fixture("crew-duplicate-other")
        let sibling = try await fixture.store.upsert(Session(
            workspaceID: fixture.workspace.id, title: "Second chat"
        ))
        try await member(fixture, "tests", of: sibling)
        let starts = Starts()

        let result = await starts.tool().call(
            request("agent_start", ["name": .string("tests"), "task": .string("Go.")]),
            as: fixture.identity, store: fixture.store
        )

        #expect(result.isError)
        #expect(result.text.contains("already has a subagent called \"tests\""))
    }

    @Test("a blank name and a missing task are each refused with what to do instead")
    func theArgumentsAreRequired() async throws {
        let fixture = try await self.fixture("crew-arguments")
        let starts = Starts()

        let noName = await starts.tool().call(
            request("agent_start", ["name": .string("   "), "task": .string("Go.")]),
            as: fixture.identity, store: fixture.store
        )
        #expect(noName.isError)
        #expect(noName.text == Crew.sentence(for: .noName))

        let noTask = await starts.tool().call(
            request("agent_start", ["name": .string("tests")]),
            as: fixture.identity, store: fixture.store
        )
        #expect(noTask.isError)
        #expect(noTask.text.contains("cannot see this conversation"))

        let blankTask = await starts.tool().call(
            request("agent_start", ["name": .string("tests"), "task": .string("\n ")]),
            as: fixture.identity, store: fixture.store
        )
        #expect(blankTask.isError)

        #expect(starts.orders.isEmpty)
    }

    /// The window's own refusal comes back as the model reads it, rather than being reworded here.
    @Test("a refusal from the window is passed through as an errored result")
    func theWindowMayStillRefuse() async throws {
        let fixture = try await self.fixture("crew-window-refusal")
        let starts = Starts()
        starts.outcome = .refused("The workspace is still installing.")

        let result = await starts.tool().call(
            request("agent_start", ["name": .string("tests"), "task": .string("Go.")]),
            as: fixture.identity, store: fixture.store
        )

        #expect(result.isError)
        #expect(result.text == "The workspace is still installing.")
    }

    /// The role gate is supposed to make this unreachable, so it is answered rather than trusted,
    /// the way `pane_open` answers the same thing.
    @Test("a connection speaking for no workspace is told so, by all four")
    func noWorkspaceOnTheToken() async throws {
        let fixture = try await self.fixture("crew-no-workspace")

        let start = await Starts().tool().call(
            request("agent_start", ["name": .string("tests"), "task": .string("Go.")]),
            as: .owner, store: fixture.store
        )
        let say = await Says().tool().call(
            request("agent_say", ["message": .string("hello")]),
            as: .owner, store: fixture.store
        )
        let list = await AgentListTool().call(
            request("agent_list"), as: .owner, store: fixture.store
        )
        let stop = await Stops().tool().call(
            request("agent_stop", ["name": .string("tests")]),
            as: .owner, store: fixture.store
        )

        for result in [start, say, list, stop] {
            #expect(result.isError)
            #expect(result.text.contains("not speaking for one"))
        }
    }

    /// A workspace archived out from under a turn that was still running in it. There is no
    /// argument in the call to correct, so the sentence must not blame one.
    @Test("a caller whose own chat has gone is told that, not told to try again")
    func theCallersRowHasGone() async throws {
        let fixture = try await self.fixture("crew-caller-gone")

        let result = await Starts().tool().call(
            request("agent_start", ["name": .string("tests"), "task": .string("Go.")]),
            as: BridgeIdentity(
                sessionID: SessionID("gone"), workspaceID: fixture.workspace.id, role: .parent
            ),
            store: fixture.store
        )

        #expect(result.isError)
        #expect(result.text.contains("no longer has the chat"))
    }

    // MARK: - Talking

    /// A crew member has exactly one agent it can talk to, so naming it would be a second way of
    /// saying the same thing, which is a second thing to get wrong. `nil` is what crosses the seam.
    @Test("a subagent talks up without naming anybody")
    func aSubagentTalksUp() async throws {
        let fixture = try await self.fixture("crew-say-up")
        let crewMember = try await member(fixture, "tests")
        let says = Says()

        let result = await says.tool().call(
            request("agent_say", ["message": .string("The parser tests pass now.")]),
            as: fixture.identity(of: crewMember), store: fixture.store
        )

        #expect(!result.isError)
        #expect(says.targets == [nil])
        #expect(says.messages == ["The parser tests pass now."])
        #expect(says.callers == [crewMember.id])
    }

    /// Allowed rather than refused as redundant: a model that has just read `agent_list` and seen
    /// who it reports to will write the name down, and refusing an unambiguous call for being over
    /// specified is the kind of pedantry that costs a turn.
    @Test("a subagent naming its own orchestrator is allowed, and still goes up as nil")
    func namingYourOwnOrchestratorIsFine() async throws {
        let fixture = try await self.fixture("crew-say-named-up")
        let crewMember = try await member(fixture, "tests")
        let says = Says()

        let result = await says.tool().call(
            request("agent_say", ["to": .string("chat"), "message": .string("Done.")]),
            as: fixture.identity(of: crewMember), store: fixture.store
        )

        #expect(!result.isError)
        #expect(says.targets == [nil])
    }

    /// There is no sideways. Every message passes through the agent that knows what the whole job
    /// is, and a call that addressed a crewmate and silently reached the orchestrator instead
    /// would look like it had worked.
    @Test("a subagent naming a crewmate is refused, not quietly redirected")
    func aSubagentCannotTalkSideways() async throws {
        let fixture = try await self.fixture("crew-say-sideways")
        let crewMember = try await member(fixture, "tests")
        try await member(fixture, "docs")
        let says = Says()

        let result = await says.tool().call(
            request("agent_say", ["to": .string("docs"), "message": .string("Take this.")]),
            as: fixture.identity(of: crewMember), store: fixture.store
        )

        #expect(result.isError)
        #expect(result.text.contains("\"Chat\" is the only agent you can talk to"))
        #expect(result.text.contains("Leave 'to' out"))
        #expect(says.messages.isEmpty)
    }

    @Test("an orchestrator must say who it is talking to")
    func anOrchestratorMustName() async throws {
        let fixture = try await self.fixture("crew-say-nobody")
        try await member(fixture, "tests")
        let says = Says()

        let result = await says.tool().call(
            request("agent_say", ["message": .string("Anybody?")]),
            as: fixture.identity, store: fixture.store
        )

        #expect(result.isError)
        #expect(result.text.contains("needs 'to'"))
        #expect(result.text.contains("agent_list"))
        #expect(says.messages.isEmpty)
    }

    /// Its own crew is `Store.crew(of:)` and not `Store.crew(inWorkspace:)`. Two chats can be
    /// running crews in one worktree, and reaching across to start a turn in somebody else's is
    /// starting a turn nobody in that conversation asked for.
    @Test("an orchestrator naming an agent that is not its own is refused with the names that are")
    func anOrchestratorCannotReachAcross() async throws {
        let fixture = try await self.fixture("crew-say-across")
        try await member(fixture, "tests")
        let sibling = try await fixture.store.upsert(Session(
            workspaceID: fixture.workspace.id, title: "Second chat"
        ))
        try await member(fixture, "theirs", of: sibling)
        let says = Says()

        let result = await says.tool().call(
            request("agent_say", ["to": .string("theirs"), "message": .string("Hello.")]),
            as: fixture.identity, store: fixture.store
        )

        #expect(result.isError)
        #expect(result.text.contains("no subagent called 'theirs'"))
        #expect(result.text.contains("tests"))
        #expect(result.text.contains("agent_list"))
        #expect(says.messages.isEmpty)
    }

    @Test("an orchestrator with no crew at all is told that, rather than told to try another name")
    func anOrchestratorWithNoCrew() async throws {
        let fixture = try await self.fixture("crew-say-empty")

        let result = await Says().tool().call(
            request("agent_say", ["to": .string("tests"), "message": .string("Hello.")]),
            as: fixture.identity, store: fixture.store
        )

        #expect(result.isError)
        #expect(result.text.contains("started no subagents"))
        #expect(result.text.contains("agent_start"))
    }

    @Test("a blank message is refused rather than delivered as nothing")
    func aBlankMessage() async throws {
        let fixture = try await self.fixture("crew-say-blank")
        try await member(fixture, "tests")
        let says = Says()

        let result = await says.tool().call(
            request("agent_say", ["to": .string("tests"), "message": .string("  \n ")]),
            as: fixture.identity, store: fixture.store
        )

        #expect(result.isError)
        #expect(result.text.contains("cannot be blank"))
        #expect(says.messages.isEmpty)
    }

    /// **The sequence that walked straight through the ceiling before `agent_say` counted.**
    /// `CrewCensus` excludes a stopped member on purpose, so it holds no slot; but `agent_say` sets
    /// a stopped member working again, which is a start in everything but name. Start three, stop
    /// one, start a fourth into the slot that freed, then say something to the stopped one, and
    /// four agents are running in one worktree. So the tool that wakes one counts exactly as
    /// `agent_start` does, over the whole workspace.
    @Test("saying something to a stopped agent is refused when the workspace is already full")
    func wakingOneIsHeldToTheCeiling() async throws {
        let fixture = try await self.fixture("crew-say-ceiling")
        let stopped = try await member(fixture, "one", state: .running)
        try await member(fixture, "two", state: .running)
        try await member(fixture, "three", state: .running)

        // Stopped, which by the census is a row rather than a running agent.
        try await fixture.store.update(sessionID: stopped.id) { $0.state = .idle }

        // So a fourth may be started, and the app's side of that start is what puts the row in.
        let starts = Starts()
        let started = await starts.tool().call(
            request("agent_start", ["name": .string("four"), "task": .string("Go.")]),
            as: fixture.identity, store: fixture.store
        )
        #expect(!started.isError)
        try await member(fixture, "four", state: .running)

        let says = Says()
        let result = await says.tool().call(
            request("agent_say", ["to": .string("one"), "message": .string("Carry on.")]),
            as: fixture.identity, store: fixture.store
        )

        #expect(result.isError)
        #expect(result.text == Crew.sentence(for: .tooMany(running: Crew.ceiling)))
        #expect(result.text.contains("agent_stop"))
        #expect(says.messages.isEmpty)
    }

    /// The other two arms of that rule, so the refusal cannot quietly become "no talking while the
    /// workspace is busy". A message to an agent whose turn is already open joins that turn rather
    /// than opening a second one, and waking a stopped agent while a slot is free is what
    /// `agent_say` is for.
    @Test("a full workspace still takes a message to a running agent, and a stopped one wakes when there is room")
    func sayingIsRefusedOnlyWhenItWouldStartAFourth() async throws {
        let fixture = try await self.fixture("crew-say-room")
        let running = try await member(fixture, "one", state: .running)
        try await member(fixture, "two", state: .running)
        try await member(fixture, "three", state: .running)
        try await member(fixture, "four", state: .cancelled)
        let says = Says()

        // A message to an agent whose turn is open joins that turn, however full the workspace is.
        let toRunning = await says.tool().call(
            request("agent_say", ["to": .string("one"), "message": .string("Also the parser.")]),
            as: fixture.identity, store: fixture.store
        )
        #expect(!toRunning.isError)
        #expect(says.targets == ["one"])

        // The fourth is a row rather than a live agent, so waking it would put a fourth writer in
        // the worktree, which is the thing the ceiling is about.
        let toStopped = await says.tool().call(
            request("agent_say", ["to": .string("four"), "message": .string("Try again.")]),
            as: fixture.identity, store: fixture.store
        )
        #expect(toStopped.isError)
        #expect(toStopped.text == Crew.sentence(for: .tooMany(running: Crew.ceiling)))

        // One of the three stops, and the same call goes through.
        try await fixture.store.update(sessionID: running.id) { $0.state = .idle }

        let afterRoom = await says.tool().call(
            request("agent_say", ["to": .string("four"), "message": .string("Try again.")]),
            as: fixture.identity, store: fixture.store
        )
        #expect(!afterRoom.isError)
        #expect(says.targets == ["one", "four"])
    }

    /// The name that crosses the seam is the name the row actually has, so the app side matches on
    /// a string it can find rather than on whatever capitals the model happened to type.
    @Test("the stored name is what crosses the seam, whatever case the caller wrote")
    func theResolvedNameIsWhatCrosses() async throws {
        let fixture = try await self.fixture("crew-say-case")
        try await member(fixture, "read-the-cascade")
        let says = Says()

        let result = await says.tool().call(
            request("agent_say", [
                "to": .string("READ-THE-CASCADE"), "message": .string("Stop at the parser."),
            ]),
            as: fixture.identity, store: fixture.store
        )

        #expect(!result.isError)
        #expect(says.targets == ["read-the-cascade"])
    }

    // MARK: - Seeing the crew

    @Test("an orchestrator sees the agents it started, with what each is doing")
    func listingYourOwnCrew() async throws {
        let fixture = try await self.fixture("crew-list")
        try await member(fixture, "tests", state: .running)
        try await member(fixture, "docs", state: .idle)

        let result = await AgentListTool().call(
            request("agent_list"), as: fixture.identity, store: fixture.store
        )

        #expect(!result.isError)
        let json = try answer(result)
        #expect(json["you"]?.stringValue == "Chat")
        #expect(json["running"]?.intValue == 1)
        #expect(json["running_limit"]?.intValue == Crew.ceiling)

        let crew = try #require(json["crew"]?.arrayValue)
        #expect(crew.compactMap { $0["name"]?.stringValue } == ["tests", "docs"])
        #expect(crew.first?["running"]?.boolValue == true)
        #expect(crew.first?["state"]?.stringValue == "running")
        #expect(crew.last?["running"]?.boolValue == false)
        // An orchestrator is not in its own crew, so nothing here should claim to be it.
        #expect(crew.allSatisfy { $0["is_you"]?.boolValue == false })
        #expect(json["orchestrator"] == nil)
    }

    /// The second arm exists because everybody in the list is editing the same files on the same
    /// branch, and an agent that cannot see who else is in the worktree cannot stay out of the way.
    @Test("a subagent sees the whole crew, itself included, and who is above it")
    func listingFromInsideTheCrew() async throws {
        let fixture = try await self.fixture("crew-list-inside")
        let crewMember = try await member(fixture, "tests", state: .running)
        try await member(fixture, "docs")

        let result = await AgentListTool().call(
            request("agent_list"), as: fixture.identity(of: crewMember), store: fixture.store
        )

        #expect(!result.isError)
        let json = try answer(result)
        #expect(json["you"]?.stringValue == "tests")
        #expect(json["orchestrator"]?.stringValue == "Chat")

        let crew = try #require(json["crew"]?.arrayValue)
        #expect(crew.compactMap { $0["name"]?.stringValue } == ["tests", "docs"])
        #expect(crew.first?["is_you"]?.boolValue == true)
        #expect(crew.last?["is_you"]?.boolValue == false)
        #expect(result.text.contains("same branch"))
    }

    @Test("an empty crew answers with a note saying how one begins")
    func listingAnEmptyCrew() async throws {
        let fixture = try await self.fixture("crew-list-empty")

        let result = await AgentListTool().call(
            request("agent_list"), as: fixture.identity, store: fixture.store
        )

        #expect(!result.isError)
        let json = try answer(result)
        #expect(json["crew"]?.arrayValue?.isEmpty == true)
        #expect(json["running"]?.intValue == 0)
        #expect(result.text.contains("agent_start"))
    }

    @Test("a full workspace says the next start will be refused")
    func listingSaysWhenTheSlotsAreGone() async throws {
        let fixture = try await self.fixture("crew-list-full")
        for name in ["one", "two", "three"] {
            try await member(fixture, name, state: .running)
        }

        let result = await AgentListTool().call(
            request("agent_list"), as: fixture.identity, store: fixture.store
        )

        #expect(json(result, "running")?.intValue == Crew.ceiling)
        #expect(result.text.contains("agent_start will be refused"))
    }

    private func json(_ result: BridgeToolResult, _ key: String) -> JSONValue? {
        JSONValue.parse(result.text)?[key]
    }

    // MARK: - Stopping one

    @Test("an orchestrator stops one of its own by name")
    func stoppingYourOwn() async throws {
        let fixture = try await self.fixture("crew-stop")
        try await member(fixture, "tests", state: .running)
        let stops = Stops()

        let result = await stops.tool().call(
            request("agent_stop", ["name": .string(" tests ")]),
            as: fixture.identity, store: fixture.store
        )

        #expect(!result.isError)
        #expect(stops.names == ["tests"])
        #expect(stops.callers == [fixture.orchestrator.id])
    }

    /// Only the chat that started a member may stop it, which is `Store.crew(of:)`. An agent
    /// reaching across to stop somebody else's crew member would be ending a turn nobody in that
    /// conversation asked to end.
    @Test("an agent cannot stop another chat's subagent")
    func stoppingAcrossChats() async throws {
        let fixture = try await self.fixture("crew-stop-across")
        let sibling = try await fixture.store.upsert(Session(
            workspaceID: fixture.workspace.id, title: "Second chat"
        ))
        try await member(fixture, "theirs", of: sibling, state: .running)
        let stops = Stops()

        let result = await stops.tool().call(
            request("agent_stop", ["name": .string("theirs")]),
            as: fixture.identity, store: fixture.store
        )

        #expect(result.isError)
        #expect(result.text.contains("started no subagents"))
        #expect(stops.names.isEmpty)
    }

    @Test("a subagent cannot stop anybody, because it started nobody")
    func aSubagentCannotStop() async throws {
        let fixture = try await self.fixture("crew-stop-subagent")
        let crewMember = try await member(fixture, "tests")
        try await member(fixture, "docs", state: .running)
        let stops = Stops()

        let result = await stops.tool().call(
            request("agent_stop", ["name": .string("docs")]),
            as: fixture.identity(of: crewMember), store: fixture.store
        )

        #expect(result.isError)
        #expect(result.text.contains("you are a subagent"))
        #expect(stops.names.isEmpty)
    }

    @Test("a name with nothing behind it is refused with the names there are")
    func stoppingAnUnknownName() async throws {
        let fixture = try await self.fixture("crew-stop-unknown")
        try await member(fixture, "tests")
        let stops = Stops()

        let result = await stops.tool().call(
            request("agent_stop", ["name": .string("typo")]),
            as: fixture.identity, store: fixture.store
        )

        #expect(result.isError)
        #expect(result.text.contains("no subagent called 'typo'"))
        #expect(result.text.contains("tests"))
        #expect(stops.names.isEmpty)
    }

    @Test("a missing name is refused with where to find one")
    func stoppingWithNoName() async throws {
        let fixture = try await self.fixture("crew-stop-noname")
        let stops = Stops()

        let result = await stops.tool().call(
            request("agent_stop", ["name": .string("  ")]),
            as: fixture.identity, store: fixture.store
        )

        #expect(result.isError)
        #expect(result.text.contains("agent_list"))
        #expect(stops.names.isEmpty)
    }

    // MARK: - Which agent a name means

    /// One answer for both tools that resolve a name, so `agent_say` and `agent_stop` cannot come
    /// to disagree about which agent was addressed.
    @Test("an exact name wins, case is ignored after it, and a pair that differ only in case is refused")
    func theLookup() {
        let workspace = WorkspaceID("w")
        let lower = Session(workspaceID: workspace, parentSessionID: SessionID("p"), title: "tests")
        let upper = Session(workspaceID: workspace, parentSessionID: SessionID("p"), title: "Tests")
        let other = Session(workspaceID: workspace, parentSessionID: SessionID("p"), title: "docs")

        #expect(CrewLookup.find("tests", among: [lower, other]) == .found(lower))
        #expect(CrewLookup.find("TESTS", among: [lower, other]) == .found(lower))
        #expect(CrewLookup.find("  tests\n", among: [lower, other]) == .found(lower))
        // An exact match wins outright, before case is ever ignored.
        #expect(CrewLookup.find("Tests", among: [lower, upper]) == .found(upper))
        #expect(CrewLookup.find("tests", among: [lower, upper]) == .found(lower))
        #expect(CrewLookup.find("TESTS", among: [lower, upper]) == .ambiguous([lower, upper]))
        #expect(CrewLookup.find("nothing", among: [lower, other]) == .unknown)
        #expect(CrewLookup.find("   ", among: [lower, other]) == .unknown)
    }
}
