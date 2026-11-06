#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
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
    /// Which of the create window's two routes this call asked for: a fresh branch cut from
    /// something, or an existing branch carried on. Defaulted to a new branch from the project's
    /// default, which is what every call made before there was a choice gets. See
    /// `AgentStartSource`.
    public let source: AgentStartSource
    /// Nil inherits whatever the calling session is using, which is almost always what is wanted:
    /// an agent asking for help wants help from the thing it already trusts.
    public let agent: AgentKind?
    /// An exact model id, or nil for the selected backend's current default.
    public let model: String?
    /// An exact reasoning effort id, or nil to inherit the calling session or Bloom's default.
    public let effort: String?

    /// What the worktree is cut from, or nil for the project's default. Nil for a checkout too,
    /// which brings its own base.
    public var baseBranch: String? { source.baseBranch }

    public init(
        prompt: String,
        name: String? = nil,
        source: AgentStartSource = .newBranch(from: nil),
        agent: AgentKind? = nil,
        model: String? = nil,
        effort: String? = nil
    ) {
        self.prompt = prompt
        self.name = name
        self.source = source
        self.agent = agent
        self.model = model
        self.effort = effort
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
    /// The project is in it only when the parent named one other than its own. The same prompt
    /// sent to two projects is two asks, and a key that ignored the project would answer the
    /// second with the first one's workspace. Left out otherwise, for two reasons: every key
    /// recorded before a parent could name a project stays the key a retry of that call produces,
    /// and naming the project the parent is already in is the same ask as naming none, so it
    /// should be the same key.
    ///
    /// Truncated to sixteen hex characters. It is a dedup key inside one database, not a
    /// cryptographic commitment, and sixty-four characters of hex in a debug print helps nobody.
    func spawnID(parentWorkspaceID: WorkspaceID, otherProject: RepoID? = nil) -> String {
        guard let otherProject else { return spawnID(scope: parentWorkspaceID.rawValue) }
        return spawnID(scope: parentWorkspaceID.rawValue + "\u{0}project\u{0}" + otherProject.rawValue)
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
        var parts = [
            scope,
            prompt,
            name ?? "",
        ] + source.digestMaterial + [
            agent?.rawValue ?? "",
        ]
        if let model { parts.append(model) }
        if let effort { parts.append(effort) }
        let material = parts.joined(separator: "\u{0}")

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

public typealias PullRequestCheckoutResolving =
    @Sendable (_ reference: String, _ repoPath: String) async -> WorkspaceCheckoutResolution

/// `workspace_start`: an agent asking Bloom for another workspace, in its own project or another.
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
/// ## A workspace an agent started may not start more
///
/// This is the one limit on nesting, and it is the lock that matters most on the whole bridge,
/// because it is what stops one runaway agent cutting worktrees without end. It is checked in the
/// handler, off the caller's own workspace row: a caller whose workspace was started by an agent
/// is refused. It used to have a role gate in front of it as well, which hid the tool from such a
/// caller, and that went with the child role (see `BridgeRole`). The tool is listed to every
/// workspace agent now and the refusal is what holds. One level is the limit, and "has a parent"
/// is the whole test, which is why there is no depth counter to drift.
///
/// The two roles that may call it differ in two ways, and both follow from one fact: a workspace
/// agent is in a workspace and the owner's client is not. They used to differ in a third, which
/// was that only a workspace agent's calls were deduplicated, and that one was a gap rather than a
/// distinction.
///
/// A workspace agent may leave the project out, and then the new workspace goes in the project it
/// is already in. It may also name one, which is how work is handed from one repository to
/// another: an agent in the site's project that finds the fix belongs in the app starts it there.
/// The owner's client must name a project, because nothing else says which. Either way the name is
/// resolved by `BridgeProjectLookup`, so both may only name a project Bloom already has and both
/// are refused in the same words when the name matches nothing or matches too much.
///
/// Naming another project changes nothing else about the call. The workspace is still `.agent`
/// origin with the caller as its parent, so the running ceiling counts it, the parent may archive
/// it, and it may not start more. Every one of those is keyed on the parent's workspace id and
/// none on its repository, which is what lets the child live somewhere else. Renaming is broader:
/// any workspace may name another explicitly, regardless of parentage.
///
/// A workspace agent's workspaces are `.agent` origin and carry its id; the owner's are `.ownerClient`
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
    private let preferences: WorkspaceStartPreferences
    private let start: WorkspaceStarting
    private let resolvePullRequest: PullRequestCheckoutResolving
    /// How a `project_checkout` call reaches a project checkout that already exists: as a new chat
    /// in it, through the same door `chat_create` uses, so the window's runner and tabs know about
    /// it. Nil refuses such a call, which only a test that does not care would leave it.
    private let addChat: ChatCreating?

    public init(
        preferences: WorkspaceStartPreferences = .init(),
        start: @escaping WorkspaceStarting,
        resolvePullRequest: @escaping PullRequestCheckoutResolving = {
            await WorkspaceCheckoutResolver.resolve($0, repoPath: $1)
        },
        addChat: ChatCreating? = nil
    ) {
        self.preferences = preferences
        self.start = start
        self.resolvePullRequest = resolvePullRequest
        self.addChat = addChat
    }

    public let roles: Set<BridgeRole> = [.workspace, .owner]

    public let tool = BridgeTool(
        name: "workspace_start",
        description: """
            Start a workspace and give it a task. It is a real git worktree on its own branch with \
            its own agent, and it appears in Bloom's sidebar for the owner to watch and review.

            Name the project to start it in with 'project', giving the name or the path that \
            project_list reports. Bloom only starts workspaces in repositories it already has, so \
            a project that is not on that list has to be registered with project_add first. \
            If you are yourself running inside a Bloom workspace, leave 'project' out to start \
            it in the project you are already in, or name another project to hand the work to that \
            repository instead. The new workspace is still counted as one you started.

            Use it when a task splits into parts that do not need to see each other's edits, and \
            you want them worked on at the same time rather than one after another.

            There are two ways to start it, the two Bloom's own create window offers, and picking \
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

            To review an existing GitHub pull request, use 'pull_request' with its number, '#123', \
            or its GitHub URL. Bloom checks out the pull request itself, preserving its base and \
            identity so the Changes, Checks and Merge controls refer to that pull request. Do not \
            create a review branch with base_branch for this purpose.

            From the owner's own client only, 'project_checkout: true' works in the project's own \
            folder instead of a worktree, on whatever branch it has checked out, with no new branch \
            and no setup. Each project has one such workspace: when it already exists, the prompt \
            starts a new chat in it rather than a second workspace. Changes made there are the \
            owner's real working copy, so use it only when the owner asked for work in the \
            project itself.

            Name only one of base_branch, existing_branch, pull_request or project_checkout.

            'model' and 'effort' are optional. Leave either out to inherit the calling chat's \
            setting, or Bloom's default when the caller has no chat. An explicit effort must be \
            one the selected model supports.

            It returns as soon as the workspace exists, not when its work is done. The new agent \
            starts on its own and keeps running while you carry on. There is no way to wait for \
            it from here, so do not ask for one and then sit idle: say what you started and get on \
            with your own work.

            Pass notify_when_done: true to have Bloom tell this chat once, by itself, when the new \
            agent's first turn comes to rest: finished (with its last message), failed (with the \
            reason), or blocked waiting on the owner for a permission prompt or a question. With \
            it, there is no need to tell the new agent to report back when it is done.

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
                            + "reports. Inside a Bloom workspace, leave it out for the project you "
                            + "are in, or name another to start the work there."
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
                "pull_request": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Open this GitHub pull request itself for review, by number, #number or "
                            + "GitHub URL. This preserves the PR connection so Bloom can show "
                            + "checks and merge it. Do not combine it with base_branch or "
                            + "existing_branch."
                    ),
                ]),
                "project_checkout": .object([
                    "type": .string("boolean"),
                    "description": .string(
                        "Work in the project's own folder on the branch it is on, instead of a "
                            + "worktree. Owner's client only. If the project already has its "
                            + "project checkout workspace, the prompt starts a new chat there. Do "
                            + "not combine it with base_branch, existing_branch or pull_request."
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
                "model": .object([
                    "type": .string("string"),
                    "description": .string(
                        "The exact model id. Claude Code models are opus, sonnet, fable and "
                            + "haiku. Codex model ids come from the signed-in Codex account, for "
                            + "example gpt-5.6-sol. Do not use a Claude Code model with codex or "
                            + "a Codex model with claudeCode. Leave this out to use the selected "
                            + "agent's default model."
                    ),
                ]),
                "effort": .object([
                    "type": .string("string"),
                    "description": .string(
                        "The exact reasoning effort id, such as low, medium or high. Leave it out "
                            + "to inherit the calling chat's effort, or Bloom's default when the "
                            + "caller has no chat."
                    ),
                ]),
                WorkspaceDoneWatch.argument: .object([
                    "type": .string("boolean"),
                    "description": .string(
                        "Have Bloom tell this chat once when the new agent's first turn comes to "
                            + "rest: finished, failed, or waiting on the owner. Defaults to false."
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
        let parent: Caller?
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
            existingBranch: filled(request.param("existing_branch")),
            pullRequest: filled(request.param("pull_request")),
            projectCheckout: WorkspaceDoneWatch.isRequested(request.param("project_checkout"))
        ) {
        case .refused(let sentence):
            return .failure(sentence)
        case .projectCheckout:
            // The owner's own folder, its real branch and the database it develops against. A
            // workspace agent is held to its own worktree everywhere else, and handing work to
            // the owner's checkout is the one move out of it this tool will not make.
            guard identity.role == .owner else {
                return .failure(
                    "project_checkout works in the owner's own project folder, so only the owner's "
                        + "client may ask for it. From a workspace, use base_branch or "
                        + "existing_branch to start a worktree instead."
                )
            }
            source = .projectCheckout
        case .newBranch(let ref):
            source = .newBranch(from: ref)
        case .existingBranch(let named):
            let branches = await AgentStartBranch.listing(of: project, store: store)
            switch AgentStartBranch.find(named, among: branches, project: project.name) {
            case .refused(let sentence): return .failure(sentence)
            case .found(let branch): source = .existingBranch(branch)
            }
        case .pullRequest(let reference):
            switch await resolvePullRequest(reference, project.path) {
            case .failure(let sentence): return .failure(sentence)
            case .checkout(.pullRequest(let request)): source = .pullRequest(request)
            case .checkout(.branch):
                return .failure("Bloom resolved that pull request as a branch instead of a pull request.")
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
            agent: agent,
            model: filled(request.param("model")),
            effort: filled(request.param("effort"))
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

        // A project checkout that already exists gets a chat, not a second workspace, and costs
        // no allowance: no row and no disk are spent. After the dedup of a call that created the
        // workspace, so a retry of that one still answers `already_started`.
        if order.source == .projectCheckout {
            if let answer = await chatInLiveProjectCheckout(
                of: project, order: order, spawnID: origin.spawnToolUseID, store: store
            ) {
                return answer
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

            let wantsNotice = WorkspaceDoneWatch.isRequested(request.param(WorkspaceDoneWatch.argument))
            var note = startedNote(for: identity.role, notifying: false)
            var notifying = false
            if wantsNotice {
                switch await watch(started, from: identity, store: store) {
                case .watching:
                    notifying = true
                    note = startedNote(for: identity.role, notifying: true)
                case .noChat:
                    note += " notify_when_done was ignored: this connection is not a chat in a "
                        + "Bloom workspace, so there is nowhere to deliver the notice."
                case .failed(let reason):
                    note += " Bloom could not record notify_when_done, so it will not tell you when "
                        + "the new agent is done: \(reason)"
                }
            }

            return .json(.object([
                "workspace_id": .string(started.workspaceID.rawValue),
                "name": .string(started.name),
                "branch": .string(started.branch),
                "path": .string(started.path),
                "state": .string("starting"),
                WorkspaceDoneWatch.argument: .bool(notifying),
                "note": .string(note),
            ]))
        } catch {
            // Two calls raced and the other one made the project checkout first. The answer is
            // the one this call would have had a moment later: a chat in it.
            if error is ProjectCheckoutTaken, let answer = await chatInLiveProjectCheckout(
                of: project, order: order, spawnID: origin.spawnToolUseID, store: store
            ) {
                return answer
            }
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
    /// One function for both roles, because the two answers differ in one place only: a caller
    /// with a workspace may leave the project out and a caller without one may not. A project that
    /// is named is looked up the same way whoever named it, so the two cannot drift into two sets
    /// of refusals.
    ///
    /// It answers with the caller rather than with a `WorkspaceOrigin`, because the origin carries
    /// the spawn key and the spawn key is a digest of the whole order, branch included, which is
    /// not settled until the branch has been found in this project. `origin(of:project:parent:)`
    /// puts the two together once both are known.
    enum Resolution {
        /// The project, and the workspace that asked. Nil is the owner's own client, which is
        /// sitting in none.
        case resolved(Repo, Caller?)
        case refused(String)
    }

    /// The workspace that asked, and the project it is sitting in. The project is carried because
    /// the spawn key has to know whether the new workspace goes somewhere else. See
    /// `AgentWorkspaceOrder.spawnID(parentWorkspaceID:otherProject:)`.
    struct Caller {
        let workspaceID: WorkspaceID
        let repoID: RepoID
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
                // The rate is not checked here. A retry of a call that already cut a worktree is
                // not another start, and `call` answers that before it counts anything, or a
                // duplicate would come back looking like a limit.
                switch try await lookUp(named, store: store) {
                case .refused(let sentence): return .refused(sentence)
                case .resolved(let project, _): return .resolved(project, nil)
                }
            }

            guard let caller = try await store.workspace(id: workspaceID) else {
                return .refused("This workspace is no longer in Bloom's database.")
            }
            guard let project = try await store.repo(id: caller.repoID) else {
                return .refused("This workspace's project is no longer in Bloom's database.")
            }

            // The nesting limit, and the only lock there is: no role hides this tool from a
            // workspace an agent started. See the head of this type.
            if caller.origin.isAgentSpawned {
                return .refused(
                    "This workspace was itself started by an agent, and those cannot start more. "
                        + "Do the work here, or report back and let the owner decide."
                )
            }

            let asking = Caller(workspaceID: workspaceID, repoID: caller.repoID)

            // A caller that is a workspace and named nothing gets its own project. One that named
            // a project gets that one, found exactly the way the owner's client finds it, so a
            // name that is not there is refused rather than quietly read as "here": a call that
            // named another project and got this one would look like it worked.
            guard let named else { return .resolved(project, asking) }
            switch try await lookUp(named, store: store) {
            case .refused(let sentence): return .refused(sentence)
            case .resolved(let named, _): return .resolved(named, asking)
            }
        } catch {
            return .refused("Bloom could not read its projects: \(error.readableMessage)")
        }
    }

    /// A project named out loud, found among the ones Bloom has, or the sentence saying why it
    /// cannot be. Answers with `Resolution` so both callers above can pass a refusal straight on;
    /// the caller half is always nil here and each fills in its own.
    private func lookUp(_ named: String, store: Store) async throws -> Resolution {
        let projects = try await store.repos()
        let outcome = BridgeProjectLookup.find(named, in: projects)
        if let refusal = BridgeProjectLookup.refusal(for: named, outcome: outcome, projects: projects) {
            return .refused(refusal)
        }
        guard case .found(let project) = outcome else {
            return .refused("Bloom has no project called '\(named)'.")
        }
        return .resolved(project, nil)
    }

    /// Who is recorded as having asked for this workspace, and the key that makes a retry of the
    /// call the same call rather than a second worktree.
    ///
    /// One function for both callers, because the difference between them is one thing: what the
    /// digest is scoped by. A parent scopes it by itself, and by the project as well when that is
    /// not its own, and the owner's client, which is not a workspace, scopes it by the project it
    /// named out loud. See `AgentWorkspaceOrder.spawnID`.
    private func origin(
        of order: AgentWorkspaceOrder, project: Repo, parent: Caller?
    ) -> WorkspaceOrigin {
        guard let parent else {
            return .ownerClient(spawnToolUseID: order.spawnID(ownerProject: project.id))
        }
        return .agent(
            parentWorkspaceID: parent.workspaceID,
            spawnToolUseID: order.spawnID(
                parentWorkspaceID: parent.workspaceID,
                otherProject: project.id == parent.repoID ? nil : project.id
            )
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
        let allowance = WorkspaceStartAllowance.of(
            origin, maximumChildren: preferences.maximumChildren
        )

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
    private func startedNote(for role: BridgeRole, notifying: Bool) -> String {
        let opening = notifying
            ? "It is setting up and will start on its own. Bloom will tell this chat once, by "
                + "itself, when its first turn comes to rest: finished, failed, or waiting on the "
                + "owner. You cannot wait for it from here, so carry on with your own work."
            : "It is setting up and will start on its own. It does not report back, and "
                + "you cannot wait for it from here. Carry on with your own work."
        guard role == .owner else { return opening }
        return opening + " When you want to know what became of it, call workspace_list."
    }

    enum WatchOutcome {
        case watching
        /// The owner's own client, which has no chat for a notice to go into.
        case noChat
        case failed(String)
    }

    /// Records `notify_when_done` for a workspace that has just been started.
    ///
    /// The first chat is read now, because the app has written it by the time `start` returns and
    /// the task goes into that chat; watching every chat would let a second one the owner opens
    /// spend the watch on the wrong turn. A workspace whose chat cannot be read is watched as a
    /// whole, subagents aside, which is the next best reading of "its first turn".
    func watch(_ started: StartedWorkspaceSummary, from identity: BridgeIdentity, store: Store) async -> WatchOutcome {
        guard let watcher = identity.sessionID, identity.workspaceID != nil else { return .noChat }
        do {
            let chat = try await store.sessions(workspaceID: started.workspaceID)
                .first { $0.parentSessionID == nil }
            try await store.addWorkspaceDoneWatch(WorkspaceDoneWatch(
                cause: .start,
                watcherSessionID: watcher,
                target: WorkspaceMessageEnd(
                    workspaceID: started.workspaceID,
                    workspace: started.name,
                    sessionID: chat?.id,
                    chat: chat?.title ?? ""
                )
            ))
            return .watching
        } catch {
            return .failed(error.readableMessage)
        }
    }

    /// The workspace an earlier run of this same call produced, if there is one and it is still
    /// here. An archived one does not count: asking again after archiving is asking again.
    /// The answer to a `project_checkout` call when the project already has its project checkout:
    /// a new chat in it with the prompt as its first message. Nil when there is none yet, and the
    /// call goes on to create it.
    ///
    /// A retry of the same call is answered from a setting keyed by its spawn id rather than with
    /// a second chat. Sessions have no spawn column, and adding one for a single caller would be a
    /// migration for a fact that is only ever read here.
    private func chatInLiveProjectCheckout(
        of project: Repo, order: AgentWorkspaceOrder, spawnID: String?, store: Store
    ) async -> BridgeToolResult? {
        guard let existing = WorkspaceKind.liveProjectCheckout(
            in: project.id, among: (try? await store.workspaces(repoID: project.id)) ?? []
        ) else { return nil }

        let repeatKey = spawnID.map { "workspaceStart.projectCheckoutChat.\($0)" }
        if let repeatKey, (try? await store.setting(repeatKey)) != nil {
            return answer(for: existing, state: "already_started", note:
                "You already asked for this one and it started a chat in the project checkout. "
                    + "Nothing new was created.")
        }

        guard let addChat else {
            return .failure(
                "The project '\(project.name)' already has its project checkout workspace, "
                    + "'\(existing.name)', and Bloom cannot add a chat to it from here."
            )
        }
        let outcome = await addChat(existing.id, ChatCreateOrder(
            agent: order.agent, model: order.model, effort: order.effort, message: order.prompt
        ))
        switch outcome {
        case .refused(let sentence):
            return .failure(sentence)
        case .created(let chat):
            if let repeatKey { try? await store.setSetting(repeatKey, chat.chatID.rawValue) }
            return answer(for: existing, state: "chat_added", note:
                "The project already had its project checkout workspace, so the task went into a "
                    + "new chat there. It runs on its own; call workspace_list or chat_read when "
                    + "you want to know what became of it.", chat: chat.json)
        }
    }

    private func answer(
        for workspace: Workspace, state: String, note: String, chat: JSONValue? = nil
    ) -> BridgeToolResult {
        var fields: [String: JSONValue] = [
            "workspace_id": .string(workspace.id.rawValue),
            "name": .string(workspace.name),
            "branch": .string(workspace.branch),
            "path": .string(workspace.path),
            "state": .string(state),
            "note": .string(note),
        ]
        if let chat { fields["chat"] = chat }
        return .json(.object(fields))
    }

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
