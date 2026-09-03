import Foundation

/// Carrying an archived workspace's conversation on in a new worktree.
///
/// **Why this exists.** Archiving removes the worktree, and when the branch has gone from this Mac
/// and from the remote as well there is nothing left to rebuild one from, so Restore is offered
/// greyed out and the archive is a reading room and nothing else. The conversation in it is not
/// finished, though. A pull request that merged and had its branch deleted on both sides is the
/// commonest way to land here, and it is exactly the case where the next thing somebody wants is
/// to keep talking to the agent that did the work.
///
/// **What is actually carried, measured rather than assumed.** Claude Code keeps a session's
/// transcript at `~/.claude/projects/<cwd with every non-alphanumeric replaced by a dash>/<session
/// id>.jsonl`, so the expectation was that a session belongs to the directory it ran in and
/// `--resume` from anywhere else would fail. It does not. Resuming session
/// `28e661ae-649a-4fa4-97c8-86fd66d72cc3` from a directory with no project folder of its own, on
/// claude 2.1.252, answered a question about the first message of that conversation correctly and
/// reported the new directory as its cwd; a made-up id from the same directory answered "No
/// conversation found with session ID". So the lookup is by id and the working directory does not
/// gate it. Codex was never in doubt: `thread/resume` takes the cwd as an argument.
///
/// So the agent genuinely remembers, and this is not a summary handed to a stranger.
///
/// **One side effect of resuming rather than forking.** Claude Code appends the carried-on turns
/// to the transcript file the archived workspace's directory owns, because that is where the
/// session already lives and the id does not change. Nothing in Bloom reads those files, so no
/// screen here is confused by it: the archive is drawn from SQLite rows keyed by the chat they
/// were written for, and the new chat's rows are the new chat's. `--fork-session` would give the
/// new conversation a file and an id of its own, and it is deliberately not used, because it
/// would mean a flag on the runner that applies to exactly one turn of one route and a session id
/// that changes under the row between the launch and the first event.
///
/// **What is not carried, and why the opening turn says so.** Bloom's own transcript rows are
/// keyed by the chat they were written for, so the new workspace's chat starts empty on screen
/// while the agent's context is full. That gap is the one thing a reader could be misled by, so
/// the handover prompt asks the agent to say in a line where the two of them got to, and the
/// archived workspace stays exactly where it is, readable, unchanged. Nothing here writes to it.
///
/// The shape is `ContinuationFacts` and `ContinuationGate` deliberately: this is the other
/// operation that carries a session past the end of the branch it was on, so the rule for when it
/// is allowed is a value gathered once and reasoned about, testable without a repository.
/// `Equatable` rather than `Hashable`, where `ContinuationFacts` is both: `RestoreSource` is
/// `Equatable` and this holds one, and widening that type to satisfy a conformance nothing here
/// needs would be the tail wagging the dog.
public struct CarryOnFacts: Sendable, Equatable {
    /// The archived workspace's branch. What the new branch is named after.
    public var branch: String
    /// The archived row's base, which is where its worktree was cut from.
    public var baseBranch: String
    /// The project's default branch, for when the archived base has itself been deleted since.
    public var defaultBranch: String
    /// Every branch the repository has right now, so the new name can avoid all of them.
    public var branches: [String]
    /// Where the branch still is, or nil while that is being worked out. Nil is not "gone": the
    /// gate refuses on it, because offering to carry a conversation on before knowing whether the
    /// workspace can simply be restored would be answering a question nobody has asked yet.
    public var restoreSource: RestoreSource?
    /// The thread the chat being read has on its backend, or nil when no agent ever ran in it.
    ///
    /// This is the whole feature. Without it there is no conversation to resume and the honest
    /// answer is to offer nothing.
    public var agentSessionID: String?
    /// Which CLI that thread belongs to.
    public var agentKind: AgentKind

    public init(
        branch: String,
        baseBranch: String,
        defaultBranch: String,
        branches: [String] = [],
        restoreSource: RestoreSource? = nil,
        agentSessionID: String? = nil,
        agentKind: AgentKind = .claudeCode
    ) {
        self.branch = branch
        self.baseBranch = baseBranch
        self.defaultBranch = defaultBranch
        self.branches = branches
        self.restoreSource = restoreSource
        self.agentSessionID = agentSessionID
        self.agentKind = agentKind
    }
}

/// Why a conversation was not offered a new workspace to carry on in.
///
/// Every one of these is a state the archive reader can genuinely be in, and none of them puts a
/// sentence on screen: the button is simply not there and Restore stands where it always did.
/// That is the difference from `ContinuationRefusal`, whose cases are all reached by pressing a
/// button and therefore all owe the presser an explanation.
public enum CarryOnRefusal: Sendable, Hashable {
    /// The branch has not been looked for yet.
    case stillLooking
    /// The project this workspace belonged to is no longer in Bloom, so there is no repository to
    /// cut a worktree from. Restore says the same thing in an alert; this one says it by not
    /// being there, because nobody has pressed anything yet.
    case projectGone
    /// The worktree can be rebuilt, so Restore is the right offer and this one would be a second
    /// answer to a question that already has a better one.
    case canBeRestored
    /// No agent ever ran in this chat, so there is no thread to resume. A workspace opened on a
    /// terminal and archived ends here.
    case neverRan
    /// The chat is on a backend Bloom has no runner for, so nothing could pick the thread up. See
    /// `AgentKind.canRunWorkspaces`.
    case backendCannotResume(AgentKind)
    /// Every candidate name for the new branch is taken or is not a name git would accept.
    case noValidName
}

public enum CarryOnDecision: Sendable, Hashable {
    case carry(CarryOnPlan)
    case refuse(CarryOnRefusal)

    public var plan: CarryOnPlan? {
        if case .carry(let plan) = self { return plan }
        return nil
    }

    public var refusal: CarryOnRefusal? {
        if case .refuse(let refusal) = self { return refusal }
        return nil
    }

    /// Whether the archive screen draws the button at all.
    public var isOffered: Bool { plan != nil }
}

/// Where the new worktree is cut, and what it is called.
public struct CarryOnPlan: Sendable, Hashable {
    /// The branch to cut. Named after the archived one by `ContinuationBranch.next`, which is the
    /// same rule a merged workspace's next branch is named by, so `dark-mode-toggle` becomes
    /// `dark-mode-toggle-2` here as well and a repository's branch prefix comes along untouched.
    ///
    /// **Never the archived branch's own name, even though nothing holds it any more.** That name
    /// is free by the time this is reached, because Restore being unavailable is precisely the
    /// branch having gone from here and from the remote, so `Git.uniqueBranch` would hand it
    /// straight back. Two things say not to take it. The new workspace keeps the archived one's
    /// name, so a new workspace on the old branch as well would be indistinguishable from the old
    /// one rather than a continuation of it, and that is the one impression this feature must not
    /// leave. And the commonest way a branch disappears from both sides is a merged pull request
    /// deleting it, which makes reusing the name a branch whose pull request is closed, back on
    /// the server the moment anybody pushes.
    public var branch: String
    /// The branch it is cut from: the archived workspace's own base while that still exists, and
    /// the project's default branch once it does not.
    public var baseBranch: String
    /// The thread to resume, which the new chat's `agentSessionID` is seeded with.
    public var agentSessionID: String
    public var agentKind: AgentKind

    public init(branch: String, baseBranch: String, agentSessionID: String, agentKind: AgentKind) {
        self.branch = branch
        self.baseBranch = baseBranch
        self.agentSessionID = agentSessionID
        self.agentKind = agentKind
    }
}

public enum CarryOnGate {
    /// Whether this archived conversation may be carried on, and where.
    ///
    /// The order runs from the least to the most specific, so the state the reader is actually in
    /// is the one that decides: a screen that has not finished looking for the branch must not
    /// report that no agent ever ran, and a workspace that can simply be restored must not be
    /// offered a second, lossier way of coming back.
    public static func decide(_ facts: CarryOnFacts) -> CarryOnDecision {
        guard let source = facts.restoreSource else { return .refuse(.stillLooking) }
        guard !source.canRebuild else { return .refuse(.canBeRestored) }

        guard let thread = facts.agentSessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !thread.isEmpty
        else { return .refuse(.neverRan) }

        guard facts.agentKind.canRunWorkspaces else {
            return .refuse(.backendCannotResume(facts.agentKind))
        }

        // The archived branch counts as taken although it is gone, which is what makes the name
        // move along by one rather than being handed straight back. See `CarryOnPlan.branch`.
        let taken = Set(facts.branches).union([facts.branch])
        let branch = ContinuationBranch.next(after: facts.branch, taken: taken)
        guard Git.isValidBranchName(branch), !taken.contains(branch) else {
            return .refuse(.noValidName)
        }

        return .carry(CarryOnPlan(
            branch: branch,
            // The archived row's base is used whenever the repository still has it, and the
            // default branch is the fallback. It is the same three-way choice the create window
            // makes when its picker's selection did not survive a branch listing, by the same
            // function, because a base that has been deleted since the archive is exactly the
            // stale selection that rule was written for.
            baseBranch: WorkspaceStartContext.resolvedBaseBranch(
                current: facts.baseBranch,
                branches: facts.branches,
                defaultBranch: facts.defaultBranch
            ),
            agentSessionID: thread,
            agentKind: facts.agentKind
        ))
    }
}

/// Everything the handover turn names, and the sentence the archive banner adds when the offer is
/// on screen.
///
/// A value rather than a string built at the press, so the wording the agent is handed can be
/// checked without a store, a worktree or a network, exactly as `WorkspaceContinuation` is.
public struct ArchivedCarryOn: Sendable, Hashable {
    /// The archived workspace's name, which the new one keeps. Bloom does not invent a name for
    /// work nobody has described yet: this is the same piece of work, carried on, and a fresh
    /// codename would hide that. See `ContinuationBranch`, which argues it at length for the
    /// merged case.
    public var name: String
    public var project: String
    /// The branch the archive was on, and that no longer exists anywhere.
    public var previousBranch: String
    /// The directory the archive was in, and that was removed with it. Named to the agent because
    /// it is holding paths under it in its own memory.
    public var previousPath: String
    public var branch: String
    public var baseBranch: String

    public init(
        name: String,
        project: String,
        previousBranch: String,
        previousPath: String,
        branch: String,
        baseBranch: String
    ) {
        self.name = name
        self.project = project
        self.previousBranch = previousBranch
        self.previousPath = previousPath
        self.branch = branch
        self.baseBranch = baseBranch
    }

    /// What the archived workspace and the plan say between them.
    ///
    /// The new worktree's own path is deliberately not in here. It does not exist until the
    /// worktree has been cut, which is after the turn this renders has been handed over, and the
    /// CLI tells the agent its working directory at the top of every run anyway. Predicting the
    /// path so as to name it would risk telling the agent it is somewhere it is not, which is
    /// worse than not saying.
    public init(workspace: Workspace, project: String, plan: CarryOnPlan) {
        self.init(
            name: workspace.name,
            project: project,
            previousBranch: workspace.branch,
            previousPath: workspace.path,
            branch: plan.branch,
            baseBranch: plan.baseBranch
        )
    }

    public func promptValues() -> [String: String] {
        [
            PromptRegistry.CarryOnArchived.workspace: name,
            PromptRegistry.CarryOnArchived.project: project,
            PromptRegistry.CarryOnArchived.previousBranch: previousBranch,
            PromptRegistry.CarryOnArchived.previousPath: previousPath,
            PromptRegistry.CarryOnArchived.branch: branch,
            PromptRegistry.CarryOnArchived.baseBranch: baseBranch,
        ]
    }

    public func render(template: String) -> PromptRender {
        PromptTemplate.render(template, values: promptValues())
    }

    /// The line the archive banner adds under `RestoreSource.explanation` when the offer stands.
    ///
    /// It is a separate sentence rather than a fourth case of that explanation because the two
    /// answer different questions. `RestoreSource` says what became of the branch, which is true
    /// whether or not anybody can do anything about it; this says what is still on offer, and
    /// depends on a chat having a thread to resume, which is not a fact about the branch at all.
    public static func standing(project: String, baseBranch: String) -> String {
        "The conversation can still be carried on: Bloom cuts a new worktree from \(baseBranch) "
            + "in \(project) and hands this chat to an agent there, with its own memory of it "
            + "intact. This archive is left exactly as it is."
    }
}

public extension WorkspaceManager {
    /// Everything `CarryOnGate` needs, read out of the repository as it stands right now.
    ///
    /// - Parameter source: where the branch was found to be, which the archive screen has already
    ///   asked for and which costs a fetch. Asking again here would put a second network call
    ///   behind a button press and give the two halves of one screen a way to disagree.
    /// - Parameter session: the chat being read. Its thread and its backend are the two facts git
    ///   cannot see.
    func carryOnFacts(
        workspace: Workspace,
        repo: Repo,
        session: Session?,
        source: RestoreSource?
    ) async -> CarryOnFacts {
        CarryOnFacts(
            branch: workspace.branch,
            baseBranch: workspace.baseBranch,
            defaultBranch: repo.defaultBranch,
            branches: (try? await Git.branches(of: repo.path)) ?? [],
            restoreSource: source,
            agentSessionID: session?.agentSessionID,
            agentKind: session?.agentKind ?? .claudeCode
        )
    }
}
