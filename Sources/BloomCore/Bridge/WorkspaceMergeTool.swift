import Foundation

/// What Bloom could find out about a workspace's pull request, in one value.
///
/// A value rather than three optionals, because "gh was not asked" and "gh answered and there is
/// nothing" are different refusals with different advice, and an optional collapses them. The same
/// distinction `WorkspaceListTool` deliberately does NOT draw, because a listing can afford to
/// leave a workspace's pull request block off and this cannot.
public enum WorkspacePullRequestReading: Sendable, Equatable {
    /// GitHub answered. `local` is what the worktree is holding, or nil when git itself could not
    /// be asked. Nil rides along rather than refusing: the worktree has already been proved to
    /// exist by the time this is read, so nil here means a git call failed, and a merge blocked by
    /// a failed `git status` would be a dead end nobody could clear.
    case found(PullRequest, local: LocalWork?)
    /// gh answered and GitHub has no pull request for this branch.
    ///
    /// Not spelled `none`, although that is what it means. `WorkspacePullRequestReading?` is what
    /// a test writes when it wants to say "use the default", and `Optional.none` shadows a case of
    /// that name at every call site, silently: the test that meant "there is no pull request"
    /// passed nil and asserted against a successful merge instead. Named for what it is.
    case noPullRequest
    /// gh could not be asked at all, so nothing is known.
    case unavailable(GitHubAccess)
    /// gh is installed and signed in, and the call still did not come back with an answer. Kept
    /// apart from `unavailable` because it is the one reading here that is usually temporary, and
    /// therefore the one refusal that can honestly say to try again.
    case failed(String)
}

/// What happened when the app was asked to send the merge request.
public enum WorkspaceMergeHandoff: Sendable, Equatable {
    /// The turn has begun. `chat` is the session it went into, which is where to watch it.
    case turnBegun(chat: String)
    /// The app would not send it, in its own words.
    case refused(String)
}

/// Asking a workspace's agent to merge, as the strip's Merge button does it.
///
/// Injected for the same reason `WorkspaceStarting` is: everything that turns a request into a
/// turn lives in the main-actor UI graph, and a bridge handler runs off it on a background task
/// per connection. The far side of this closure is `WorkspaceModel.requestMerge`, unchanged and
/// not copied, so the prompt an MCP caller triggers is the prompt the button composes, rendered
/// against the template the owner may have edited in Settings, with the project's own
/// `.bloom/merge-instructions.md` attached by the same code path. **One way to move a state.**
public typealias WorkspaceMergeRequesting =
    @Sendable (Workspace, PullRequest, GitHub.MergeMethod) async -> WorkspaceMergeHandoff

/// `workspace_merge`: asking a workspace's own agent to land its pull request.
///
/// ## Why this is allowed to exist now, when it was refused before
///
/// A merge tool was designed and turned down once, and the reasoning was right at the time. Bloom
/// merged by calling `gh pr merge` and then deleting the remote branch, `PullRequestStatus.canMerge`
/// is deliberately permissive (true over failing checks, no review, and uncommitted work on disk),
/// and every piece of protection lived in the confirmation dialogue: "None of that is part of what
/// is merged", "Bloom cannot undo this". A tool reading `can_merge: true` skipped the only
/// protective part of the whole arrangement.
///
/// Bloom does not merge any more. `GitHub.merge` and `deleteRemoteBranch` are gone. Merging is a
/// prompt composed from `PromptRegistry.mergePullRequest`, sent into the workspace's chat, and run
/// by the agent under the owner's eyes. That is what makes a tool possible.
///
/// ## The old objection did not evaporate, it moved, and here is where
///
/// The safety is now a person watching a turn in a chat they have open. **An MCP caller is not
/// that person.** So this tool absorbs what the dialogue was doing, which is why it refuses in two
/// places the button does not:
///
/// - The dialogue's loudest paragraph warns about a worktree holding work GitHub has not got. The
///   button stays live over it because a person can read the warning and weigh it; there is nobody
///   here to read it, so this refuses instead. See `WorkspaceMergeTrouble.localWork`.
/// - The dialogue is raised by a press, so it cannot be raised into a busy workspace by accident.
///   A message can, and it would queue. This refuses anything that would queue rather than start,
///   because "a turn has begun" is the one thing this call promises.
///
/// The second half of the objection is that a tool which sends the merge prompt is mechanically a
/// tool that can put text into somebody's chat. This one cannot be steered: there is no free text
/// argument anywhere on it. Its two arguments are a workspace id and one of three merge methods,
/// and the sentence that goes down the wire is rendered from the owner's own template by the app's
/// own code. Nothing a caller types reaches the agent.
///
/// ## It is not on `BridgeToolApproval.selfApproved`, deliberately
///
/// That list is for tools Bloom answers a permission question about on its own behalf, and its own
/// note says what is kept off it: anything a person should answer for. Publishing to a shared
/// server is exactly that. A caller of this tool should stop on the ask.
///
/// ## Owner only
///
/// A parent merging its own child's work is a different and more dangerous thing: it is an agent
/// approving an agent's work and publishing it, with the review step nobody performed. It is also
/// shaped wrong for a parent, which is implicitly scoped to the worktree it sits in and would have
/// to name another workspace out loud to use this at all, which is the widening the role gate
/// exists to prevent. A child reports and nothing else, here as everywhere.
public struct WorkspaceMergeTool: BridgeToolHandling {
    /// How the pull request and the worktree's local work are read. Injected so every refusal can
    /// be tested without gh, a network or a real repository.
    public typealias Reading = @Sendable (Workspace) async -> WorkspacePullRequestReading

    private let merge: WorkspaceMergeRequesting
    private let read: Reading

    public init(
        read: @escaping Reading = WorkspaceMergeTool.ask,
        merge: @escaping WorkspaceMergeRequesting
    ) {
        self.read = read
        self.merge = merge
    }

    public let roles: Set<BridgeRole> = [.owner]

    public let tool = BridgeTool(
        name: "workspace_merge",
        description: """
            Ask a workspace's own agent to merge its pull request.

            This does not merge anything. It composes the request Bloom's own Merge button \
            composes, with the project's merge instructions attached, and sends it into that \
            workspace's chat as an ordinary message. The agent runs `gh pr merge` there, in front \
            of the owner, under whatever permission mode they set, and can say what GitHub \
            answered if it refuses.

            So it returns once the turn has begun, and the merging happens inside that turn, after \
            this call is over. Nothing has landed on GitHub when this answers, and the merge may \
            still not happen. Do not report a pull request as merged on the strength of this call. \
            Call workspace_list with include_github afterwards and read the state.

            It refuses a pull request GitHub will not take, a worktree holding work GitHub has not \
            got, and a workspace whose agent is busy. When it refuses, do not run `gh pr merge` \
            yourself and do not ask another agent to. Merging publishes to a server other people \
            share, and Bloom only does it where the owner can watch it happen.

            Name the workspace by the id workspace_list reports, not by its name. It squash merges \
            unless you say otherwise.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "workspace": .object([
                    "type": .string("string"),
                    "description": .string(
                        "The workspace whose pull request to merge, by the id workspace_list "
                            + "reports. Not its name: two workspaces may share one."
                    ),
                ]),
                "method": .object([
                    "type": .string("string"),
                    "enum": .array(GitHub.MergeMethod.allCases.map { .string($0.rawValue) }),
                    "description": .string(
                        "How to merge it. Leave it out for squash, which is what Bloom's own "
                            + "button proposes."
                    ),
                ]),
            ]),
            "required": .array([.string("workspace")]),
        ])
    )

    public func call(
        _ request: MCPRequest,
        as identity: BridgeIdentity,
        store: Store
    ) async -> BridgeToolResult {
        guard let given = request.stringParam("workspace")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !given.isEmpty
        else {
            return .failure(
                "workspace_merge needs the workspace whose pull request to merge. Call "
                    + "workspace_list and pass the id it reports as 'id'."
            )
        }

        let method: GitHub.MergeMethod
        if let raw = request.stringParam("method") {
            guard let chosen = GitHub.MergeMethod(rawValue: raw) else {
                return .failure(
                    "Bloom does not know a merge method called '\(raw)'. It merges by "
                        + GitHub.MergeMethod.allCases.map { "'\($0.rawValue)'" }
                        .joined(separator: ", ")
                        + ". Leave the argument out for squash."
                )
            }
            method = chosen
        } else {
            method = .squash
        }

        let workspace: Workspace
        do {
            guard let found = try await store.workspace(id: WorkspaceID(given)) else {
                return .failure(WorkspaceMergeTrouble.unknownWorkspace(
                    id: given, alias: try await alias(for: given, store: store)
                ).sentence)
            }
            workspace = found
        } catch {
            return .failure("Bloom could not read that workspace: \(error.readableMessage)")
        }

        guard workspace.state != .archived else {
            return .failure(WorkspaceMergeTrouble.archived(workspace: workspace.name).sentence)
        }
        guard FileManager.default.fileExists(atPath: workspace.path) else {
            return .failure(WorkspaceMergeTrouble.worktreeGone(workspace: workspace.name).sentence)
        }

        // Asked before GitHub, because a busy workspace is refused whatever GitHub says and a gh
        // call costs a second the caller would spend for nothing.
        do {
            if let hold = try await hold(on: workspace, store: store) {
                return .failure(
                    WorkspaceMergeTrouble.wouldQueue(workspace: workspace.name, hold: hold).sentence
                )
            }
        } catch {
            return .failure("Bloom could not read that workspace's chats: \(error.readableMessage)")
        }

        let pullRequest: PullRequest
        let local: LocalWork?
        switch await read(workspace) {
        case .unavailable(let access):
            return .failure(WorkspaceMergeTrouble.githubUnavailable(access).sentence)
        case .failed(let message):
            return .failure(WorkspaceMergeTrouble.githubSilent(message).sentence)
        case .noPullRequest:
            return .failure(WorkspaceMergeTrouble.noPullRequest(
                workspace: workspace.name, branch: workspace.branch
            ).sentence)
        case let .found(found, foundLocal):
            pullRequest = found
            local = foundLocal
        }

        // The same gate the button asks, weighed the same way, quoted rather than re-derived. See
        // `PullRequestStatus` for why `status(local:)` and not `status`.
        let status = pullRequest.status(local: local)

        guard status.canMerge else {
            return .failure(WorkspaceMergeTrouble.blocked(
                workspace: workspace.name,
                number: pullRequest.number,
                headline: status.text,
                reason: status.blockedReason ?? "GitHub will not take it in this state."
            ).sentence)
        }

        // Where this tool parts company with the button, and the only place it does. `remedy` is
        // anything but `.merge` exactly when the local weighing changed the answer, which is the
        // paragraph the confirmation puts at the top and that there is nobody here to read.
        if status.remedy != .merge, let local {
            return .failure(WorkspaceMergeTrouble.localWork(
                workspace: workspace.name,
                number: pullRequest.number,
                detail: PullRequest.localDetail(local),
                needsCommit: status.remedy == .commitAndPush
            ).sentence)
        }

        switch await merge(workspace, pullRequest, method) {
        case .refused(let sentence):
            return .failure(WorkspaceMergeTrouble.appRefused(sentence).sentence)
        case .turnBegun(let chat):
            return .json(answer(
                workspace: workspace,
                pullRequest: pullRequest,
                method: method,
                chat: chat
            ))
        }
    }

    // MARK: What the caller is told on the way out

    /// The success answer, which has one job beyond naming things: it must not be readable as
    /// "merged".
    ///
    /// `state` is `turn_started` rather than anything with "merge" in it, `note` opens by saying
    /// nothing is merged, and the two facts after that are the ones `workspace_start`'s own note
    /// established for a call that answers before its work happens: there is no way to wait for it
    /// from here, and `workspace_list` is what says what became of it. The last sentence is this
    /// tool's own: the turn can end without a merge, because GitHub is allowed to refuse and the
    /// instructions tell the agent to stop and say so when it does.
    private func answer(
        workspace: Workspace,
        pullRequest: PullRequest,
        method: GitHub.MergeMethod,
        chat: String
    ) -> JSONValue {
        .object([
            "state": .string("turn_started"),
            "workspace_id": .string(workspace.id.rawValue),
            "workspace": .string(workspace.name),
            "chat": .string(chat),
            "pull_request": .integer(pullRequest.number),
            "url": .string(pullRequest.url),
            "base_branch": .string(workspace.baseBranch),
            "method": .string(method.phrase),
            "note": .string(note(
                workspace: workspace, pullRequest: pullRequest, chat: chat
            )),
        ])
    }

    private func note(workspace: Workspace, pullRequest: PullRequest, chat: String) -> String {
        """
        Nothing is merged. A turn has begun in '\(workspace.name)', in the chat '\(chat)': its \
        agent has been asked to merge #\(pullRequest.number) and it runs `gh pr merge` itself, \
        where the owner can watch it and answer anything it asks. Bloom does not wait for that \
        turn and there is no way to wait for it from here, so do not sit idle. The merge may still \
        not happen: GitHub is allowed to refuse, and the agent is told to stop and report a \
        refusal rather than force it. To find out what became of it, call workspace_list with \
        include_github and read the pull request's state.
        """
    }

    // MARK: Diagnosing what was actually typed

    /// Whether the caller typed a name or a branch where an id belongs.
    ///
    /// Worked out by asking the database rather than by guessing at the shape of the string, which
    /// is the same route `WorkspaceStartTrouble.diagnose` takes and for the same reason: a caller
    /// told only "no such workspace" retries with the other names it has, and there is a whole
    /// listing tool's worth of them within reach.
    ///
    /// Archived workspaces are included, because being told "that name belongs to an archived
    /// workspace" is a better answer than being told the name means nothing.
    private func alias(for given: String, store: Store) async throws -> WorkspaceMergeTrouble.Alias {
        let all = try await store.workspaces(includeArchived: true)
        let matches = all.filter {
            $0.name.caseInsensitiveCompare(given) == .orderedSame
                || $0.branch.caseInsensitiveCompare(given) == .orderedSame
        }
        guard let first = matches.first else { return .none }
        guard matches.count == 1 else {
            return .several(name: first.name, count: matches.count)
        }
        return .one(name: first.name, id: first.id.rawValue)
    }

    /// Why a message sent into this workspace right now would queue, or nil when it would go.
    ///
    /// `DeliveryHold` rather than a rule of this tool's own, so the two places that decide whether
    /// a message may move cannot drift. It is asked of every chat in the workspace and the first
    /// hold wins, which is wider than the button's guard: the button knows which chat is on screen
    /// and this cannot, so it refuses if any of them is busy. The narrower gate is still there and
    /// still the real one, on the far side of `WorkspaceMergeRequesting`, checked on the main actor
    /// against the live transcripts. A turn that starts between this look and that one comes back
    /// as `WorkspaceMergeTrouble.appRefused`.
    private func hold(on workspace: Workspace, store: Store) async throws -> DeliveryHold? {
        let sessions = try await store.sessions(workspaceID: workspace.id)
        let isRunningSetup = workspace.setupState == .running
        let didSetupFail = workspace.setupState == .failed

        // A workspace with no chat at all is asked about anyway, because the setup states hold a
        // message on their own and belong to the workspace rather than to any chat. It is not
        // otherwise held: `requestMerge` opens a chat, exactly as the button does for a workspace
        // whose agent was never started.
        var held = DeliveryHold.of(
            isRunningSetup: isRunningSetup,
            didSetupFail: didSetupFail,
            isTurnRunning: false,
            isAwaitingQuestion: false
        )

        for session in sessions where held == .none {
            held = DeliveryHold.of(
                isRunningSetup: isRunningSetup,
                didSetupFail: didSetupFail,
                isTurnRunning: session.state == .running,
                isAwaitingQuestion: session.state == .waiting
            )
        }

        return held == .none ? nil : held
    }

    // MARK: Asking GitHub for real

    /// The default reading: what GitHub says about the branch, and what the worktree is holding.
    ///
    /// `maxAge` is zero rather than the sixty seconds `workspace_list` allows itself. A listing is
    /// a glance and a minute-old answer costs nothing; this one decides whether to publish, and a
    /// cached "Ready to merge" from before somebody pushed a broken commit is the wrong kind of
    /// cheap.
    public static let ask: Reading = { workspace in
        do {
            guard let pullRequest = try await GitHub.pullRequest(
                forBranch: workspace.branch, worktree: workspace.path
            ) else {
                // gh answered and there is nothing, but only if gh could answer at all. Asked
                // second because it costs a subprocess and the common case never needs it.
                let access = await GitHub.access()
                return access == .ready ? .noPullRequest : .unavailable(access)
            }
            let local = try? await Git.localWork(worktree: workspace.path)
            return .found(pullRequest, local: local)
        } catch {
            // gh threw. Which of the two it is decides the advice, so it is asked rather than
            // assumed: an unusable gh is permanent and a failed call usually is not.
            let access = await GitHub.access()
            return access == .ready ? .failed(plainly(error)) : .unavailable(access)
        }
    }

    /// gh's complaint without the command line Bloom built to provoke it.
    ///
    /// `ShellError.readableMessage` is the whole invocation, its exit status and its stderr, and
    /// measured against a worktree with no remote that came out as the full `gh pr view` argv with
    /// ten `--json` fields in it. That is a command line in a tool result, which is the thing this
    /// file's siblings refuse to emit: it invites the model to reason about gh rather than about
    /// the tool it called, and the flags are the one part of the failure the caller neither chose
    /// nor can change. The same trim as `WorkspaceStartTrouble.plainly`, which exists for the same
    /// sentence in git's voice.
    static func plainly(_ error: any Error) -> String {
        guard let shell = error as? ShellError else { return error.readableMessage }
        let stderr = shell.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stderr.isEmpty else { return "gh exited \(shell.status) without saying why." }
        return stderr.hasSuffix(".") ? stderr : stderr + "."
    }
}
