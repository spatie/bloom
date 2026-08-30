import Foundation

/// The four tools an orchestrator runs a crew with: `agent_start`, `agent_say`, `agent_list` and
/// `agent_stop`.
///
/// One file, because they are one subject and each of them is the same question read from a
/// different end: who is asking, which agent do they mean, and may they. `Crew` holds the rules
/// and its head argues the whole feature; `CrewSeam` holds the verbs that cross into the window.
/// What is here is the translation between an MCP call and those two, which is reading the
/// arguments, working out who the caller is, refusing in a sentence a model can act on, and only
/// then handing over.
///
/// **A crew member's address is its name, and its name is its chat's title.** There is no id in
/// any of these tools, on purpose: the orchestrator invented the name in the same breath as the
/// task, so it is the one string it already has, and a name it can read back in the sidebar is a
/// name the owner and the agent are talking about the same thing with. `Store.crew(of:)` is what
/// turns one back into a row.
///
/// **The depth limit is one and it is enforced here rather than counted.** A caller whose own
/// session has a `parentSessionID` is a crew member, and a crew member may not start one. That
/// test is a column rather than a number kept beside it, for the reason `BridgeRole` gives about
/// children: a depth counter drifts out of step with the thing it describes, and a flat crew has
/// no cycle to deadlock in.
///
/// **`.parent` and nothing else, for all four.** A crew member's session lives in an ordinary
/// workspace, so its token already carries `.parent` and it reaches these tools through the same
/// gate its orchestrator does; the split between the two is made inside each handler, off the
/// caller's own row, rather than by a fourth role nobody could mint. Not `.owner`, which is
/// sitting in no workspace and so has no crew to be talking about, and not `.child`, which
/// reports and that is all.

/// The four names, written once. Each appears in its own schema, in the refusals the other three
/// give, and in `BridgeToolApproval.selfApproved`, and a name that is right in three of those
/// places and wrong in the fourth is a tool an agent is told to call and cannot find.
enum CrewToolName {
    static let start = "agent_start"
    static let say = "agent_say"
    static let list = "agent_list"
    static let stop = "agent_stop"
}

/// Which crew members count against `Crew.ceiling`, and which are just rows.
///
/// **Not "anything that is not idle", which is the obvious reading and the wrong one.** `failed`
/// and `cancelled` are terminal: an agent that died counted as running would hold a third of a
/// workspace's allowance until the workspace was archived, and three of them would lock a
/// worktree out of ever starting another with nothing on screen to explain why. `waiting` counts,
/// because a process holding its turn open on a question is a live agent in the worktree with a
/// bill attached, which is exactly what the ceiling is about.
///
/// The switch is exhaustive rather than a `default`, so a new `SessionState` has to be argued
/// about here instead of falling quietly into one of the two answers.
enum CrewCensus {
    static func isRunning(_ session: Session) -> Bool {
        switch session.state {
        case .running, .waiting: true
        case .idle, .failed, .cancelled: false
        }
    }
}

/// Turning the name a caller said into the crew member it meant.
///
/// `BridgeWorkspaceLookup` one door over, in the same shape and for the same reason: the moment a
/// name crosses the socket there is a thing to get wrong, and resolving it in one place keeps
/// `agent_say` and `agent_stop` from ever disagreeing about which agent was addressed.
///
/// An exact match wins outright, and only then is case ignored. `Crew.start` compares names for
/// uniqueness exactly, so "tests" and "Tests" can both exist in one workspace, and a caller that
/// wrote one of them precisely must get that one. Two members that differ only in case are
/// refused rather than resolved to whichever was started first: stopping the agent the caller did
/// not name is the one outcome these tools must not have.
public enum CrewLookup: Sendable {
    public enum Outcome: Sendable, Equatable {
        case found(Session)
        case unknown
        case ambiguous([Session])
    }

    public static func find(_ query: String, among crew: [Session]) -> Outcome {
        guard let name = Crew.normalisedName(query) else { return .unknown }

        if let exact = crew.first(where: { $0.title == name }) { return .found(exact) }

        let matches = crew.filter { $0.title.caseInsensitiveCompare(name) == .orderedSame }
        switch matches.count {
        case 0: return .unknown
        case 1: return .found(matches[0])
        default: return .ambiguous(matches)
        }
    }
}

/// The chat that is asking, and which side of the crew it is on.
struct CrewCaller {
    let session: Session
    let workspaceID: WorkspaceID

    /// A chat somebody else's agent started. `Session.parentSessionID` is the whole test.
    var isCrewMember: Bool { session.parentSessionID != nil }

    /// Whose crew this caller's questions are about: its own, or its orchestrator's when it is
    /// itself a crew member. That second arm is what lets an agent see who else is on the job,
    /// which matters here in a way it does not for children: everyone in this list is writing the
    /// same files on the same branch.
    var crewAnchor: SessionID { session.parentSessionID ?? session.id }

    static func resolve(
        _ identity: BridgeIdentity,
        store: Store,
        tool: String
    ) async -> Result<CrewCaller, CrewToolTrouble> {
        guard let sessionID = identity.sessionID, let workspaceID = identity.workspaceID else {
            return .failure(.notInAWorkspace(tool: tool))
        }

        do {
            guard let session = try await store.session(id: sessionID) else {
                return .failure(.callerHasGone(tool: tool))
            }
            return .success(CrewCaller(session: session, workspaceID: workspaceID))
        } catch {
            return .failure(.unexplained(tool: tool, error.readableMessage))
        }
    }
}

/// Why one of the four would not act, in terms a model can act on.
///
/// Built to the `WorkspaceRenameTrouble` standard and for the same reason: a model told "invalid
/// input" tries the same call again. Every sentence names the argument that was wrong, says
/// whether retrying unchanged can help, and says what would have worked instead. The refusals
/// `Crew` already owns are not repeated here, because the wording of a start refusal belongs
/// beside the rule that produced it.
public enum CrewToolTrouble: Error, Sendable, Equatable {
    /// A connection with no session or no workspace on its token reached a tool that is entirely
    /// about the workspace it is standing in. The role gate is supposed to make this impossible,
    /// so it is answered rather than trusted, the way `pane_open` answers it.
    case notInAWorkspace(tool: String)
    /// The caller's own row is gone, which is a workspace archived out from under a turn that was
    /// still running in it. There is no argument in the call to correct, so the sentence must not
    /// blame one.
    case callerHasGone(tool: String)
    case noTask
    case noMessage
    case noNameToStop
    /// A crew member named somebody other than the agent above it. Carries that agent's name when
    /// Bloom still has its row, because "talk to your orchestrator" is worth less than its name.
    case talkedSideways(given: String, orchestrator: String?)
    /// An orchestrator called `agent_say` with nothing to say it to.
    case saidToNobody
    case unknownMember(tool: String, given: String, known: [String])
    /// Two crew members whose names differ only in case. Rare, and refused rather than guessed at.
    case ambiguousMember(tool: String, given: String)
    /// A crew member reached for `agent_stop`. It started nothing, so it has nothing to stop.
    case stoppingIsTheOrchestratorsCall
    case unexplained(tool: String, String)

    public var sentence: String {
        switch self {
        case .notInAWorkspace(let tool):
            return """
                \(tool) is about the agents working in the workspace you are in, and this \
                connection is not speaking for one.
                """

        case .callerHasGone(let tool):
            return """
                Bloom no longer has the chat this connection speaks for, so \(tool) cannot tell \
                whose crew you mean. Its row has gone, which retrying will not undo.
                """

        case .noTask:
            return """
                agent_start needs a 'task'. It becomes the first message in the new agent's chat \
                and it is everything that agent gets, because it cannot see this conversation. \
                Write it to the agent rather than about it, and say what finished looks like.
                """

        case .noMessage:
            return """
                agent_say needs a 'message' to deliver and it cannot be blank. There is nothing \
                on this side of the socket to type one into.
                """

        case .noNameToStop:
            return """
                agent_stop needs the 'name' of the subagent to stop. Call agent_list for the \
                names you may use.
                """

        case let .talkedSideways(given, orchestrator):
            let target = orchestrator.map { "\"\($0)\"" } ?? "the agent that started you"
            return """
                You are a subagent, so \(target) is the only agent you can talk to, and \
                '\(given)' is not it. Leave 'to' out and your message goes up. If a crewmate of \
                yours needs to hear something, say it upwards and let the agent that started you \
                both decide.
                """

        case .saidToNobody:
            return """
                agent_say needs 'to': the name of the subagent to say it to. Call agent_list for \
                the names of yours. Only a subagent may leave it out, because a subagent has \
                exactly one agent it can talk to.
                """

        case let .unknownMember(tool, given, known):
            guard !known.isEmpty else {
                return """
                    You have started no subagents, so there is none called '\(given)' for \(tool) \
                    to reach. Retrying will not change that: agent_start is how a crew begins.
                    """
            }
            return """
                You have no subagent called '\(given)'. Yours are: \
                \(BridgeWorkspaceLookup.list(known)). Retrying with the same name will fail the \
                same way, so call agent_list and use a name from its answer.
                """

        case let .ambiguousMember(tool, given):
            return """
                Two of your subagents answer to '\(given)' with only their capitals to tell them \
                apart, so \(tool) would be acting on one you did not name. Write the name exactly \
                as agent_list prints it.
                """

        case .stoppingIsTheOrchestratorsCall:
            return """
                agent_stop stops the subagents you started yourself, and you are a subagent: you \
                started none. If one of the agents on this job should stop, say so to the agent \
                that started you and let it decide.
                """

        case let .unexplained(tool, message):
            return "Bloom could not complete \(tool): \(message)"
        }
    }
}

/// `agent_start`: put a second agent in the worktree you are already in.
///
/// ## What it is for, and the test that tells it from `workspace_start`
///
/// A subagent shares this worktree and this branch, so everything the crew does lands in one diff
/// and one pull request. That is the whole point of it and it is also the whole hazard: two agents
/// editing the same files at the same time is a thing an orchestrator has to plan for rather than
/// discover. The test between the two tools is how many pull requests the caller expects at the
/// end. One, and it is this; several, and it is `workspace_start`, which cuts a worktree and a
/// branch of its own. `Crew`'s head argues that split at length.
///
/// ## Why it is self-approved
///
/// `BridgeToolApproval` holds the argument. The short of it is that an orchestrator that has to
/// stop and ask the owner before it can put its own crew together is an orchestrator that hangs on
/// an unattended turn, and nothing this reaches is outside the workspace the caller is already in.
public struct AgentStartTool: BridgeToolHandling {
    private let start: CrewStarting

    public init(_ start: @escaping CrewStarting) {
        self.start = start
    }

    public let roles: Set<BridgeRole> = [.parent]

    public let tool = BridgeTool(
        name: CrewToolName.start,
        description: """
            Start a subagent: a second agent in the workspace you are already in, with a task of \
            its own, which you can talk to and which reports back to you when it stops.

            It shares this worktree and this branch. Everything you and it do lands in one diff \
            and one pull request, which is the point of it: use it when a job splits into parts \
            that have to end up as one change, such as one agent reading a large area while you \
            write, or one keeping the tests green while you work on the next thing.

            If the work needs its own branch and its own pull request, this is the wrong tool. \
            Use workspace_start, which cuts a worktree of its own for it.

            'name' is required and is yours to invent. Make it short and make it say what the \
            agent is for, such as 'tests' or 'read-the-cascade': it is what the sidebar draws, it \
            is the address agent_say and agent_stop take, and it has to be unique in this \
            workspace.

            'task' is required and is everything the agent gets. It cannot see this conversation, \
            so write it as if to somebody who has just opened the project, and say what finished \
            looks like. Because you are both editing the same files, say which files or which \
            area are its, and keep off them yourself.

            'model' and 'effort' are optional and default to the ones you are running on.

            It returns as soon as the agent has started, not when its work is done. You are told \
            when it stops and what it last said, so do not sit and wait for it: say what you \
            started and get on with your own work.

            Three subagents may run in one workspace at once. This costs real money and puts a \
            second writer in your working tree, so start one because the work genuinely divides. \
            A subagent cannot start subagents of its own.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "name": .object([
                    "type": .string("string"),
                    "description": .string(
                        "What to call it. Short, unique in this workspace, and about what the "
                            + "agent is for. This is how you address it afterwards."
                    ),
                ]),
                "task": .object([
                    "type": .string("string"),
                    "description": .string(
                        "The brief, written for somebody who cannot see this conversation. Say "
                            + "which files are the agent's, and what finished looks like."
                    ),
                ]),
                "model": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Which model it runs on. Leave it out for the one you are running on."
                    ),
                ]),
                "effort": .object([
                    "type": .string("string"),
                    "description": .string(
                        "How hard it thinks. Leave it out for the setting you are running on."
                    ),
                ]),
            ]),
            "required": .array([.string("name"), .string("task")]),
        ])
    )

    public func call(
        _ request: MCPRequest,
        as identity: BridgeIdentity,
        store: Store
    ) async -> BridgeToolResult {
        let caller: CrewCaller
        switch await CrewCaller.resolve(identity, store: store, tool: CrewToolName.start) {
        case .failure(let trouble): return .failure(trouble.sentence)
        case .success(let resolved): caller = resolved
        }

        let crew: [Session]
        do {
            crew = try await store.crew(inWorkspace: caller.workspaceID)
        } catch {
            return .failure(
                CrewToolTrouble.unexplained(tool: CrewToolName.start, error.readableMessage).sentence
            )
        }

        // Counted from the database rather than from anything held in memory, so two calls racing
        // cannot both read the same stale number and both be allowed through. Names are every crew
        // member in the workspace, running or not, because a stopped agent keeps its conversation
        // and its row; the ceiling is counted over the live ones only. See `Crew.start`.
        let refusalOrName = Crew.start(
            name: request.stringParam("name") ?? "",
            existing: Set(crew.map(\.title)),
            running: crew.filter(CrewCensus.isRunning).count,
            callerIsSubagent: caller.isCrewMember
        )

        let name: String
        switch refusalOrName {
        case .failure(let refusal): return .failure(Crew.sentence(for: refusal))
        case .success(let accepted): name = accepted
        }

        guard let task = Self.text(request.stringParam("task")) else {
            return .failure(CrewToolTrouble.noTask.sentence)
        }

        let order = CrewOrder(
            name: name,
            task: task,
            model: Self.text(request.stringParam("model")),
            effort: Self.text(request.stringParam("effort"))
        )

        switch await start(order, caller.session.id, caller.workspaceID) {
        case .started(let sentence): return BridgeToolResult(text: sentence)
        case .refused(let refusal): return .failure(refusal)
        }
    }

    /// An argument with something in it, or nil. Blank and absent are the same thing everywhere in
    /// this file: a model that passed `""` meant to pass nothing, and a task of two spaces is a
    /// chat opened with nothing in it.
    static func text(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}

/// `agent_say`: put a message in another agent's chat.
///
/// ## The shape of it is the whole design, and it is deliberately asymmetric
///
/// An orchestrator talks down and names which of its crew it means. A crew member talks up and
/// names nobody, because it has exactly one agent it can talk to and naming it would be a second
/// way of saying the same thing, which is a second thing to get wrong. A crew member that does
/// name somebody is refused rather than quietly redirected: a call that addressed a crewmate and
/// silently reached the orchestrator instead would look like it worked.
///
/// There is no sideways. Two crew members cannot talk to each other, and that is the property that
/// keeps a crew a crew rather than a mesh: every message passes through the agent that knows what
/// the whole job is, and there is no ring of agents to deadlock on one another.
public struct AgentSayTool: BridgeToolHandling {
    private let say: CrewSaying

    public init(_ say: @escaping CrewSaying) {
        self.say = say
    }

    public let roles: Set<BridgeRole> = [.parent]

    public let tool = BridgeTool(
        name: CrewToolName.say,
        description: """
            Say something to another agent working in this workspace.

            If you started subagents, 'to' is the name of the one you mean and is required. Use \
            it to hand over something you have found, to change what an agent is doing, or to \
            answer a question it asked you.

            If you are yourself a subagent, leave 'to' out: your message goes to the agent that \
            started you, which is the only agent you can talk to. Say what you have found and \
            what you need. You cannot address the other subagents on this job, so anything they \
            need to hear goes up and comes back down.

            The message lands in that agent's chat and starts a turn there, exactly as though the \
            owner had typed it, so write it as a message rather than as a report about one. It \
            returns once the message has been delivered, not once the agent has answered.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "to": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Which of your subagents to say it to, by the name agent_list prints. "
                            + "Required from the agent that started them. Leave it out if you "
                            + "are a subagent: your message goes to the agent above you."
                    ),
                ]),
                "message": .object([
                    "type": .string("string"),
                    "description": .string("What to say, written to that agent."),
                ]),
            ]),
            "required": .array([.string("message")]),
        ])
    )

    public func call(
        _ request: MCPRequest,
        as identity: BridgeIdentity,
        store: Store
    ) async -> BridgeToolResult {
        guard let message = AgentStartTool.text(request.stringParam("message")) else {
            return .failure(CrewToolTrouble.noMessage.sentence)
        }

        let caller: CrewCaller
        switch await CrewCaller.resolve(identity, store: store, tool: CrewToolName.say) {
        case .failure(let trouble): return .failure(trouble.sentence)
        case .success(let resolved): caller = resolved
        }

        let named = AgentStartTool.text(request.stringParam("to"))

        let target: String?
        if caller.isCrewMember {
            switch await talkingUp(named: named, caller: caller, store: store) {
            case .failure(let trouble): return .failure(trouble.sentence)
            case .success: target = nil
            }
        } else {
            switch await talkingDown(named: named, caller: caller, store: store) {
            case .failure(let trouble): return .failure(trouble.sentence)
            case .success(let member): target = member
            }
        }

        switch await say(target, message, caller.session.id, caller.workspaceID) {
        case .delivered(let sentence): return BridgeToolResult(text: sentence)
        case .refused(let refusal): return .failure(refusal)
        }
    }

    /// A crew member may name its own orchestrator or name nobody, and nothing else.
    ///
    /// Naming it is allowed rather than refused as redundant, because a model that has just read
    /// `agent_list` and seen who it reports to will write the name down, and refusing an
    /// unambiguous call for being over specified is the kind of pedantry that costs a turn.
    private func talkingUp(
        named: String?,
        caller: CrewCaller,
        store: Store
    ) async -> Result<Void, CrewToolTrouble> {
        guard let named else { return .success(()) }

        guard let parentID = caller.session.parentSessionID else { return .success(()) }
        let orchestrator: Session?
        do {
            orchestrator = try await store.session(id: parentID)
        } catch {
            return .failure(.unexplained(tool: CrewToolName.say, error.readableMessage))
        }

        guard let orchestrator,
              Crew.normalisedName(named)?.caseInsensitiveCompare(orchestrator.title) == .orderedSame
        else {
            return .failure(.talkedSideways(given: named, orchestrator: orchestrator?.title))
        }

        return .success(())
    }

    /// An orchestrator must name one of its own, and `Store.crew(of:)` is what "its own" means.
    /// Every other agent in the workspace, including the crew of a chat beside it, resolves to
    /// nothing here.
    private func talkingDown(
        named: String?,
        caller: CrewCaller,
        store: Store
    ) async -> Result<String, CrewToolTrouble> {
        guard let named else { return .failure(.saidToNobody) }

        let crew: [Session]
        do {
            crew = try await store.crew(of: caller.session.id)
        } catch {
            return .failure(.unexplained(tool: CrewToolName.say, error.readableMessage))
        }

        switch CrewLookup.find(named, among: crew) {
        case .found(let member):
            return .success(member.title)
        case .unknown:
            return .failure(
                .unknownMember(tool: CrewToolName.say, given: named, known: crew.map(\.title))
            )
        case .ambiguous:
            return .failure(.ambiguousMember(tool: CrewToolName.say, given: named))
        }
    }
}

/// `agent_list`: who is on this job.
///
/// The one of the four that needs no seam into the window, so it is in `BridgeToolbox.standard`.
/// A crew is rows in the `sessions` table joined by `parent_session_id`, and `Store` is an actor a
/// handler on a background task calls directly. Nothing here is held in memory on the main actor,
/// which is what put the tab tools on the other side of that line.
///
/// It answers about the crew rather than about the caller's children, and the two arms are the
/// asymmetry `agent_say` has: an orchestrator sees the agents it started, and a crew member sees
/// its crewmates as well as itself. That second arm exists because everybody in the list is
/// editing the same files on the same branch, and an agent that cannot see who else is in the
/// worktree cannot stay out of their way.
public struct AgentListTool: BridgeToolHandling {
    public init() {}

    public let roles: Set<BridgeRole> = [.parent]

    public let tool = BridgeTool(
        name: CrewToolName.list,
        description: """
            List the agents working in this workspace beside you: what each is called, whether it \
            is running, and what it is doing. Call it before agent_say or agent_stop, because the \
            name is how those two address an agent.

            If you started subagents, it lists yours. If you are yourself a subagent, it lists the \
            whole crew, so you can see who else is in this worktree. Everyone in the list shares \
            this branch and these files, so somebody named here as running is somebody who may be \
            editing what you are about to edit.

            It takes no arguments, it reads and changes nothing, and it says how many of the \
            three running slots are taken.
            """,
        inputSchema: BridgeTool.noArguments
    )

    public func call(
        _ request: MCPRequest,
        as identity: BridgeIdentity,
        store: Store
    ) async -> BridgeToolResult {
        let caller: CrewCaller
        switch await CrewCaller.resolve(identity, store: store, tool: CrewToolName.list) {
        case .failure(let trouble): return .failure(trouble.sentence)
        case .success(let resolved): caller = resolved
        }

        let crew: [Session]
        let orchestrator: Session?
        do {
            crew = try await store.crew(of: caller.crewAnchor)
            orchestrator = caller.isCrewMember
                ? try await store.session(id: caller.crewAnchor)
                : caller.session
        } catch {
            return .failure(
                CrewToolTrouble.unexplained(tool: CrewToolName.list, error.readableMessage).sentence
            )
        }

        let running = crew.filter(CrewCensus.isRunning).count

        var answer: [String: JSONValue] = [
            "you": .string(caller.session.title),
            "you_are": .string(caller.isCrewMember ? "subagent" : "the agent that started them"),
            "crew": .array(crew.map { member in
                .object([
                    "name": .string(member.title),
                    "running": .bool(CrewCensus.isRunning(member)),
                    "state": .string(member.state.rawValue),
                    "is_you": .bool(member.id == caller.session.id),
                ])
            }),
            "running": .integer(running),
            "running_limit": .integer(Crew.ceiling),
            "note": .string(Self.note(crew: crew, running: running, caller: caller)),
        ]

        // Named only for a crew member, because an orchestrator reading its own name back under
        // this key would have to work out whether it meant somebody above it.
        if caller.isCrewMember, let orchestrator {
            answer["orchestrator"] = .string(orchestrator.title)
        }

        return .json(.object(answer))
    }

    private static func note(crew: [Session], running: Int, caller: CrewCaller) -> String {
        guard !crew.isEmpty else {
            return caller.isCrewMember
                ? "You are the only agent on this job. Anything you need goes up, with agent_say."
                : "You have started no subagents. agent_start is how one begins, and it shares "
                    + "this worktree and this branch with you."
        }

        let slots = Crew.ceiling - running
        let room = slots > 0
            ? "\(slots) of the \(Crew.ceiling) running slots are free."
            : "All \(Crew.ceiling) running slots are taken, so agent_start will be refused until "
                + "one of them stops."

        return caller.isCrewMember
            ? "Everyone here is editing the same files on the same branch as you. \(room) You can "
                + "only talk upwards: agent_say with no 'to' reaches the agent that started you."
            : "Everyone here is editing the same files on the same branch as you. \(room) Talk to "
                + "one with agent_say, and stop one with agent_stop."
    }
}

/// `agent_stop`: end a subagent you started.
///
/// **Only the chat that started a member may stop it**, which is `Store.crew(of:)` and not
/// `Store.crew(inWorkspace:)`. Two orchestrators can be running crews in one worktree, and an
/// agent reaching across to stop somebody else's would be ending a turn nobody in that
/// conversation asked to end. A crew member is refused outright: it started nothing, so there is
/// nothing it could be naming that is its to stop.
///
/// It is not destructive in the sense `BridgeToolApproval` reserves that word for. The chat, its
/// conversation and everything the agent wrote in the worktree stay exactly where they are, which
/// is why the description says so out loud: a model that read this as "undo that agent's work"
/// would call it expecting a revert.
public struct AgentStopTool: BridgeToolHandling {
    private let stop: CrewStopping

    public init(_ stop: @escaping CrewStopping) {
        self.stop = stop
    }

    public let roles: Set<BridgeRole> = [.parent]

    public let tool = BridgeTool(
        name: CrewToolName.stop,
        description: """
            Stop a subagent you started, by name. Use it when what it was given is no longer \
            wanted, when it is working on something you have decided against, or when you need \
            the slot, because three subagents may run in one workspace at once.

            'name' is required and is the name agent_list prints.

            It ends that agent's turn and leaves it idle. Its chat, its conversation and \
            everything it has already written in the worktree stay where they are: this stops an \
            agent, it does not undo its work, and the row stays in the sidebar for the owner to \
            read. You can talk to a stopped agent again with agent_say, which starts it working \
            once more.

            Only the agent that started a subagent may stop it.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "name": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Which of your subagents to stop, by the name agent_list prints."
                    ),
                ]),
            ]),
            "required": .array([.string("name")]),
        ])
    )

    public func call(
        _ request: MCPRequest,
        as identity: BridgeIdentity,
        store: Store
    ) async -> BridgeToolResult {
        guard let named = AgentStartTool.text(request.stringParam("name")) else {
            return .failure(CrewToolTrouble.noNameToStop.sentence)
        }

        let caller: CrewCaller
        switch await CrewCaller.resolve(identity, store: store, tool: CrewToolName.stop) {
        case .failure(let trouble): return .failure(trouble.sentence)
        case .success(let resolved): caller = resolved
        }

        guard !caller.isCrewMember else {
            return .failure(CrewToolTrouble.stoppingIsTheOrchestratorsCall.sentence)
        }

        let crew: [Session]
        do {
            crew = try await store.crew(of: caller.session.id)
        } catch {
            return .failure(
                CrewToolTrouble.unexplained(tool: CrewToolName.stop, error.readableMessage).sentence
            )
        }

        let member: Session
        switch CrewLookup.find(named, among: crew) {
        case .found(let found):
            member = found
        case .unknown:
            return .failure(
                CrewToolTrouble.unknownMember(
                    tool: CrewToolName.stop, given: named, known: crew.map(\.title)
                ).sentence
            )
        case .ambiguous:
            return .failure(
                CrewToolTrouble.ambiguousMember(tool: CrewToolName.stop, given: named).sentence
            )
        }

        switch await stop(member.title, caller.session.id, caller.workspaceID) {
        case .stopped(let sentence): return BridgeToolResult(text: sentence)
        case .refused(let refusal): return .failure(refusal)
        }
    }
}
