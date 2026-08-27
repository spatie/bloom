import CryptoKit
import Foundation

/// What an agent asked Bloom to start, once the arguments have been read and checked.
///
/// A value rather than a dictionary handed onwards, so the checking happens once, here, and the
/// app side receives something that cannot be malformed. `WorkspaceStartRequest` is the seam this
/// eventually becomes; this is the tool's half of the translation.
public struct AgentWorkspaceOrder: Sendable, Hashable {
    public let prompt: String
    /// Nil lets Bloom name it the way it names any other workspace.
    ///
    /// Not made unique, and that is a decision rather than an omission. Two `workspace_start`
    /// calls naming the same thing do produce two rows with the same label, which was raised as a
    /// defect; suffixing it would be worse in three ways. The name is the sentence the agent has
    /// already said out loud to the owner ("I started Sentry importer"), and quietly turning it
    /// into "Sentry importer 2" makes that report wrong. Nothing resolves a workspace by name: the
    /// id, the branch and the path are all unique, and the branch is what the sidebar shows
    /// beneath the label, so the rows are told apart on screen. And the owner may already name two
    /// workspaces the same from the sheet, which does not dedupe either, so a rule that applied
    /// only to the tool would make the two doors behave differently for no reason visible from
    /// either. The accidental duplicate, a retried call, is already handled by `spawnID`.
    public let name: String?
    /// Which of the create sheet's two routes this call asked for: a fresh branch cut from
    /// something, or an existing branch carried on. Defaulted to a new branch from the project's
    /// default, which is what every call made before there was a choice gets. See
    /// `AgentStartSource`.
    public let source: AgentStartSource
    /// Nil inherits whatever the calling session is using, which is almost always what is wanted:
    /// an agent asking for help wants help from the thing it already trusts.
    public let agent: AgentKind?

    /// What the worktree is cut from, or nil for the project's default. Nil for a checkout too,
    /// which brings its own base.
    public var baseBranch: String? { source.baseBranch }

    public init(
        prompt: String,
        name: String? = nil,
        source: AgentStartSource = .newBranch(from: nil),
        agent: AgentKind? = nil
    ) {
        self.prompt = prompt
        self.name = name
        self.source = source
        self.agent = agent
    }
}

/// What the tool answers with once the workspace exists.
///
/// Deliberately small, and deliberately not a status. The call returns the moment the worktree and
/// the row exist; setup and the first turn are still ahead of it. Anything richer would invite the
/// caller to read it as "finished".
public struct StartedWorkspaceSummary: Sendable, Hashable {
    public let workspaceID: WorkspaceID
    public let name: String
    public let branch: String
    public let path: String

    public init(workspaceID: WorkspaceID, name: String, branch: String, path: String) {
        self.workspaceID = workspaceID
        self.name = name
        self.branch = branch
        self.path = path
    }
}

extension AgentWorkspaceOrder {
    /// A name for this call that a repeat of it would produce again.
    ///
    /// `WorkspaceOrigin.spawnToolUseID` is documented as the thing that stops a retried spawn
    /// cutting a second worktree, and it could not do that job while it was a fresh UUID: two
    /// identical calls produced two ids and therefore two worktrees. **MCP does not carry the
    /// model's `tool_use` id to the server**, so the real one is not available to record and no
    /// amount of plumbing inside Bloom will make it appear.
    ///
    /// What is available is the call itself, and a retry is by definition the same call. Digesting
    /// it gives an id that repeats exactly when the thing it names repeats, which is the property
    /// the column was added for. The parent is in the digest so two workspaces asking for the same
    /// thing are two spawns, which they are.
    ///
    /// Truncated to sixteen hex characters. It is a dedup key inside one database, not a
    /// cryptographic commitment, and sixty-four characters of hex in a debug print helps nobody.
    func spawnID(parentWorkspaceID: WorkspaceID) -> String {
        spawnID(scope: parentWorkspaceID.rawValue)
    }

    /// The same name, for the owner's own client, which has no workspace to scope it by.
    ///
    /// The project takes the parent's place in the digest, and it has to: the owner names one out
    /// loud, so the same prompt against two projects is two asks, and a key that ignored the
    /// project would answer the second with the first one's workspace.
    ///
    /// Nothing else stands in for the caller, because there is only one owner. Two terminals on
    /// the same machine asking for the same thing in the same project is the case this is meant
    /// to collapse, not one it should tell apart.
    func spawnID(ownerProject: RepoID) -> String {
        spawnID(scope: "owner\u{0}" + ownerProject.rawValue)
    }

    private func spawnID(scope: String) -> String {
        let material = ([
            scope,
            prompt,
            name ?? "",
        ] + source.digestMaterial + [
            agent?.rawValue ?? "",
        ]).joined(separator: "\u{0}")

        let digest = SHA256.hash(data: Data(material.utf8))

        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// Starting a workspace, as the app does it.
///
/// Injected rather than called, because the tool runs off the main actor on a background task per
/// connection, and everything that makes a workspace actually *run* lives in the main-actor UI
/// graph: the model that streams setup into the transcript and sends the opening turn. A handler
/// that called `WorkspaceManager.start` on its own would create a worktree on disk that no agent
/// ever runs in, which is worse than refusing.
///
/// The project and the origin are worked out here and passed in rather than derived on the far
/// side. They used to be read from the caller's own workspace row by the app, which was possible
/// only while every caller had one; the owner's standalone client has no workspace, names its
/// project out loud, and produces a workspace of `.user` origin. Deciding both in one place keeps
/// the two callers from drifting into two answers.
public typealias WorkspaceStarting =
    @Sendable (AgentWorkspaceOrder, Repo, BridgeIdentity, WorkspaceOrigin) async throws
        -> StartedWorkspaceSummary

/// `workspace_start`: an agent asking Bloom for another workspace in the same project.
///
/// **Not `workspace_spawn`, and nothing here says "subagent".** A workspace an agent asked for is
/// an ordinary Bloom workspace with an ordinary agent in it, which is what `WorkspaceOrigin` says
/// in as many words and what the seam is called. The vocabulary is load-bearing: a name that
/// implied a lesser kind of workspace would be describing something Bloom does not have.
///
/// ## It returns before the work starts, on purpose
///
/// The call answers as soon as the worktree, the row and the session exist, which is seconds.
/// Setup and the opening turn run afterwards, under Bloom's own runners, while the caller carries
/// on with its own turn. Both keep running. Blocking until the child finished would hold the
/// caller's turn open for as long as the work took, and would hold this connection's serve loop
/// with it, so every later bridge call from that session would queue behind it.
///
/// ## A child may not call it, and the two who may are not alike
///
/// The role gate is the first lock and it hides the tool from a child's `tools/list` entirely, so
/// a child is never tempted by a tool it cannot use. The second lock is below: a caller whose own
/// workspace was started by an agent is refused even if it speaks raw MCP at the socket. One level
/// of nesting is the limit, and "has a parent" is the whole test, which is why there is no depth
/// counter to drift.
///
/// The two roles that may call it differ in two ways, and both follow from one fact: a parent is
/// a workspace and the owner's client is not. They used to differ in a third, which was that only
/// a parent's calls were deduplicated, and that one was a gap rather than a distinction.
///
/// A parent cannot name a project, because its own is the only one it may act in, and `project` is
/// refused rather than ignored if it names one. The owner's client must name a project, because
/// nothing else says which, and it may only name one Bloom already has.
///
/// A parent's workspaces are `.agent` origin and carry its id; the owner's are `.ownerClient`
/// origin and carry no parent. How many either may start is not decided here: `WorkspaceOrigin`
/// answers it through `WorkspaceStartAllowance`, which holds all three answers, the sheet's
/// included, in one switch.
///
/// Both roles are deduplicated by a digest of the call, because a model retries and a retried
/// spawn cuts a second worktree. The owner's used to be exempt on the grounds that `.user` had
/// nowhere to record the key, which was true of `.user` and is the reason `.ownerClient` exists.
/// The argument that two identical asks a minute apart from a person are two asks is an argument
/// about the Create sheet, where each of them is a press; here neither of them is.
public struct WorkspaceStartTool: BridgeToolHandling {
    private let start: WorkspaceStarting

    public init(start: @escaping WorkspaceStarting) {
        self.start = start
    }

    public let roles: Set<BridgeRole> = [.parent, .owner]

    public let tool = BridgeTool(
        name: "workspace_start",
        description: """
            Start a workspace and give it a task. It is a real git worktree on its own branch with \
            its own agent, and it appears in Bloom's sidebar for the owner to watch and review.

            Name the project to start it in with 'project', giving the name or the path that \
            project_list reports. Bloom only starts workspaces in repositories it already has, so \
            register one with project_add first if it is not on that list. If you are yourself \
            running inside a Bloom workspace, leave 'project' out: you can only start work in the \
            project you are already in.

            Use it when a task splits into parts that do not need to see each other's edits, and \
            you want them worked on at the same time rather than one after another.

            There are two ways to start it, the two Bloom's own create sheet offers, and picking \
            the wrong one is the mistake worth avoiding here.

            '\(WorkspaceSourceTab.newBranch.title)' is the default and needs nothing said. \
            \(WorkspaceSourceTab.newBranch.explanation) Name the branch to cut from with \
            'base_branch', or leave it out for the project's default branch.

            '\(WorkspaceSourceTab.existingBranch.title)' is 'existing_branch'. \
            \(WorkspaceSourceTab.existingBranch.explanation) Use it to carry on, review or fix \
            work that is already on a branch: cutting a new branch off that branch instead gives \
            you a workspace whose diff is empty, because it starts out identical to the branch \
            you named. The branch has to exist already, and git allows one worktree per branch, \
            so a branch another workspace is sitting on is refused rather than opened twice.

            Name one or the other, never both.

            It returns as soon as the workspace exists, not when its work is done. The new agent \
            starts on its own and keeps running while you carry on. There is no way to wait for \
            it from here, so do not ask for one and then sit idle: say what you started and get on \
            with your own work.

            The task you give it is all it gets. It cannot see this conversation, so write the \
            prompt as if to someone who has just opened the project for the first time.

            This costs real money and real disk. Start one because the work genuinely divides, \
            not to parallelise something you could do in a single pass. A workspace that was \
            itself started this way cannot start others.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "project": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Which project to start it in, by the name or the path project_list "
                            + "reports. Leave it out if you are running inside a Bloom workspace."
                    ),
                ]),
                "prompt": .object([
                    "type": .string("string"),
                    "description": .string(
                        "The task, written for someone with no context beyond the project itself."
                    ),
                ]),
                "name": .object([
                    "type": .string("string"),
                    "description": .string(
                        "What to call it in the sidebar. Leave it out and Bloom names it from the task."
                    ),
                ]),
                "base_branch": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Cut a new branch from this one. Your commits land on the new branch and "
                            + "merge back into this one. Leave it out for the project's default "
                            + "branch. Do not name it together with existing_branch."
                    ),
                ]),
                "existing_branch": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Work on this branch itself, instead of cutting a new one. Your commits "
                            + "land on it. It has to exist already, locally or on the remote, and "
                            + "it must not be open in another workspace. Do not name it together "
                            + "with base_branch."
                    ),
                ]),
                "agent": .object([
                    "type": .string("string"),
                    "enum": .array(AgentKind.runnable.map { .string($0.rawValue) }),
                    "description": .string(
                        "Which agent runs it. Leave it out for the one you are running on, or "
                            + "for Bloom's own default if you are not running in Bloom."
                    ),
                ]),
            ]),
            "required": .array([.string("prompt")]),
        ])
    )

    public func call(
        _ request: MCPRequest,
        as identity: BridgeIdentity,
        store: Store
    ) async -> BridgeToolResult {
        // `params` here are already the call's arguments: the dispatch unwraps them so a handler
        // cannot forget to. See `BridgeDispatch.callTool`.
        guard let prompt = request.stringParam("prompt"),
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .failure("workspace_start needs a prompt saying what the new workspace should do.")
        }

        let agent = agent(in: request)
        if let requested = request.stringParam("agent"), agent == nil {
            return .failure(
                "Bloom cannot run '\(requested)'. It runs "
                    + AgentKind.runnable.map(\.rawValue).joined(separator: " and ")
                    + ". Leave the argument out to use the same agent you are running on."
            )
        }

        // The project is resolved here rather than only on the happy path, because it is what
        // makes a failed start explicable: `WorkspaceStartTrouble` needs the repository's name,
        // its path and the branch a call that named none would have been cut from. It is also what
        // the branch below is looked for in, and what the spawn key of a caller with no workspace
        // is scoped by, so it is settled before either.
        let project: Repo
        let parent: WorkspaceID?
        switch await resolve(request, as: identity, store: store) {
        case .refused(let sentence): return .failure(sentence)
        case let .resolved(repo, caller):
            project = repo
            parent = caller
        }

        // Which of the sheet's two routes this is, with the branch found in the project rather
        // than taken on trust. A name that is not there, or one something else is already sitting
        // on, is answered in a sentence here: the alternative is a start that fails inside git,
        // or worse, a workspace on a branch nobody asked for. See `AgentStartSource`.
        let source: AgentStartSource
        switch AgentStartRequest.read(
            baseBranch: filled(request.param("base_branch")),
            existingBranch: filled(request.param("existing_branch"))
        ) {
        case .refused(let sentence):
            return .failure(sentence)
        case .newBranch(let ref):
            source = .newBranch(from: ref)
        case .existingBranch(let named):
            let branches = await AgentStartBranch.listing(of: project, store: store)
            switch AgentStartBranch.find(named, among: branches, project: project.name) {
            case .refused(let sentence): return .failure(sentence)
            case .found(let branch): source = .existingBranch(branch)
            }
        }

        let order = AgentWorkspaceOrder(
            prompt: prompt,
            // `WorkspaceName.given` rather than `filled`, which is otherwise the same trim, so
            // that the two doors a name can arrive through cannot drift: `workspace_rename` reads
            // its argument with the same function, and a name this door accepts and that one
            // refuses would be a workspace an agent can create and then cannot correct.
            name: WorkspaceName.given(request.stringParam("name")),
            source: source,
            agent: agent
        )
        let origin = origin(of: order, project: project, parent: parent)

        if let spawnID = origin.spawnToolUseID {
            do {
                if let existing = try await alreadyStarted(spawnID: spawnID, store: store) {
                    return .json(.object([
                        "workspace_id": .string(existing.id.rawValue),
                        "name": .string(existing.name),
                        "branch": .string(existing.branch),
                        "path": .string(existing.path),
                        "state": .string("already_started"),
                        "note": .string(
                            "You already asked for this one and it exists. Nothing new was created."
                        ),
                    ]))
                }
            } catch {
                return .failure(
                    "Bloom could not check for a repeat of this call: \(error.readableMessage)"
                )
            }
        }

        // After the dedup, and that order is the rule rather than a preference. A retry of a call
        // that already cut a worktree is not another start, and answering it with a limit is how a
        // duplicate comes back looking like a runaway. It used to hold for the owner's client only,
        // because the two brakes were checked in two places.
        do {
            if let refusal = try await overAllowance(origin, store: store) { return .failure(refusal) }
        } catch {
            return .failure(
                "Bloom could not check how many workspaces it has started recently: "
                    + error.readableMessage
            )
        }

        do {
            let started = try await start(order, project, identity, origin)

            return .json(.object([
                "workspace_id": .string(started.workspaceID.rawValue),
                "name": .string(started.name),
                "branch": .string(started.branch),
                "path": .string(started.path),
                "state": .string("starting"),
                "note": .string(startedNote(for: identity.role)),
            ]))
        } catch {
            let trouble = await WorkspaceStartTrouble.diagnose(
                error,
                project: project.name,
                projectPath: project.path,
                // Whichever branch this call actually named, which for a checkout is the branch it
                // asked to carry on. Diagnosing against the default there would answer a call
                // about one branch with a sentence about another.
                baseBranch: order.source.namedBranch ?? project.defaultBranch,
                wasRequested: order.source.namedBranch != nil
            )
            return .failure(trouble.sentence)
        }
    }

    /// Which project this workspace goes in and which workspace, if any, is asking, or the
    /// sentence saying why neither can be answered.
    ///
    /// One function for both roles, because the two answers have to stay opposite: a caller with a
    /// workspace may not name a project and a caller without one must. Split across two call sites
    /// that would eventually become one that does neither.
    ///
    /// It answers with the caller rather than with a `WorkspaceOrigin`, because the origin carries
    /// the spawn key and the spawn key is a digest of the whole order, branch included, which is
    /// not settled until the branch has been found in this project. `origin(of:project:parent:)`
    /// puts the two together once both are known.
    enum Resolution {
        /// The project, and the workspace that asked. Nil is the owner's own client, which is
        /// sitting in none.
        case resolved(Repo, WorkspaceID?)
        case refused(String)
    }

    func resolve(
        _ request: MCPRequest,
        as identity: BridgeIdentity,
        store: Store
    ) async -> Resolution {
        let named = filled(request.param("project"))

        do {
            guard let workspaceID = identity.workspaceID else {
                // The owner's own client. It has no workspace, so the project is the one thing it
                // cannot be excused from saying.
                guard let named else {
                    return .refused(
                        "workspace_start needs a project, because this connection is not running "
                            + "inside a Bloom workspace and nothing else says where the work "
                            + "should go. Call project_list to see what Bloom has."
                    )
                }
                let projects = try await store.repos()
                let outcome = BridgeProjectLookup.find(named, in: projects)
                if let refusal = BridgeProjectLookup.refusal(
                    for: named, outcome: outcome, projects: projects
                ) {
                    return .refused(refusal)
                }
                guard case .found(let project) = outcome else {
                    return .refused("Bloom has no project called '\(named)'.")
                }
                // The rate is not checked here. A retry of a call that already cut a worktree is
                // not another start, and `call` answers that before it counts anything, or a
                // duplicate would come back looking like a limit.
                return .resolved(project, nil)
            }

            // A caller that is a workspace. Its project is decided for it, so naming one is a
            // misunderstanding worth correcting rather than an argument to drop on the floor: a
            // call that named another project and quietly got this one would look like it worked.
            if let named {
                return .refused(
                    "workspace_start does not take a project here. You are running inside a Bloom "
                        + "workspace, so the new one goes in the project you are already in, and "
                        + "'\(named)' is not something this call can change. Ask again without it."
                )
            }

            guard let caller = try await store.workspace(id: workspaceID) else {
                return .refused("This workspace is no longer in Bloom's database.")
            }
            guard let project = try await store.repo(id: caller.repoID) else {
                return .refused("This workspace's project is no longer in Bloom's database.")
            }

            // The second lock. The role gate already hid this tool from a child, so reaching here
            // as one means something spoke MCP at the socket directly.
            if caller.origin.isAgentSpawned {
                return .refused(
                    "This workspace was itself started by an agent, and those cannot start more. "
                        + "Do the work here, or report back and let the owner decide."
                )
            }

            return .resolved(project, workspaceID)
        } catch {
            return .refused("Bloom could not read its projects: \(error.readableMessage)")
        }
    }

    /// Who is recorded as having asked for this workspace, and the key that makes a retry of the
    /// call the same call rather than a second worktree.
    ///
    /// One function for both callers, because the difference between them is one thing: what the
    /// digest is scoped by. A parent scopes it by itself, and the owner's client, which is not a
    /// workspace, scopes it by the project it named out loud. See `AgentWorkspaceOrder.spawnID`.
    private func origin(
        of order: AgentWorkspaceOrder, project: Repo, parent: WorkspaceID?
    ) -> WorkspaceOrigin {
        guard let parent else {
            return .ownerClient(spawnToolUseID: order.spawnID(ownerProject: project.id))
        }
        return .agent(
            parentWorkspaceID: parent,
            spawnToolUseID: order.spawnID(parentWorkspaceID: parent)
        )
    }

    /// Whether this caller has already had as many as its origin allows, and the sentence saying
    /// so.
    ///
    /// One function for all three origins, because there is one question. Which brake applies is
    /// `WorkspaceStartAllowance.of`, and the only thing that genuinely differs here is the count
    /// each one is measured against: a parent's is how many of its children are running, and the
    /// owner's is how many have been started inside the window.
    ///
    /// Both are counted from the database rather than kept in memory. See the allowance.
    ///
    /// `now` is a parameter so the window can be tested without waiting a quarter of an hour.
    func overAllowance(
        _ origin: WorkspaceOrigin, store: Store, now: Date = Date()
    ) async throws -> String? {
        let allowance = WorkspaceStartAllowance.of(origin)

        switch allowance {
        case .unlimited:
            return nil

        case .running:
            guard let parent = origin.parentWorkspaceID else { return nil }
            let live = try await store.workspaces(startedBy: parent)
            return allowance.refusal(count: live.count)

        case .rate(_, let window):
            let recent = try await store.workspacesStartedByOwnerClient(
                since: now.addingTimeInterval(-window)
            )
            return allowance.refusal(count: recent.count)
        }
    }

    /// The note on a workspace that has just been started, which differs by who is being told.
    ///
    /// The owner's client gets a sentence naming `workspace_list`, because it can call it and
    /// because without it "you cannot wait for it from here" means "and there is nothing else to
    /// call either". A parent does not, because `workspace_list` is not in its `tools/list` and
    /// naming a tool a caller cannot reach is worse than naming none.
    private func startedNote(for role: BridgeRole) -> String {
        let opening = "It is setting up and will start on its own. It does not report back, and "
            + "you cannot wait for it from here. Carry on with your own work."
        guard role == .owner else { return opening }
        return opening + " When you want to know what became of it, call workspace_list."
    }

    /// The workspace an earlier run of this same call produced, if there is one and it is still
    /// here. An archived one does not count: asking again after archiving is asking again.
    private func alreadyStarted(spawnID: String, store: Store) async throws -> Workspace? {
        try await store.workspaces(spawnToolUseID: spawnID).first { $0.state != .archived }
    }

    private func filled(_ value: JSONValue?) -> String? {
        guard let text = value?.stringValue else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The requested agent, or nil for "use the caller's". An unrecognised name is also nil, and
    /// the caller above turns that into a refusal rather than silently choosing for it.
    private func agent(in request: MCPRequest) -> AgentKind? {
        guard let raw = request.stringParam("agent") else { return nil }
        guard let kind = AgentKind(rawValue: raw), kind.canRunWorkspaces else { return nil }
        return kind
    }
}
