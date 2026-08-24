import Foundation

/// `workspace_list`: the workspaces Bloom has, for a client that is sitting in none.
///
/// **The tool that closes the loop `workspace_start` opens.** That call answers the moment the
/// worktree exists, tells the caller plainly that there is no way to wait for the work, and until
/// this existed there was nothing else to call either: `whoami` answered `"workspaces": 12`, a
/// number with no ids, no names and no states behind it. The owner's client could cut a worktree,
/// a branch and a running agent, and was blind from that instant.
///
/// ## It reads and it quotes
///
/// Every field except the GitHub block comes out of Bloom's own database, so the default call is a
/// handful of `SELECT`s and reaches nothing outside the process. There is no seam into the app and
/// no main actor, which is why it lives in `BridgeToolbox.standard` beside `project_list`.
///
/// **There is no one type that knows which button is active, and this does not invent a fifth.**
/// Four gates decide four different things in four files, and they are not a hierarchy:
/// `WorkspaceStatus` is a verdict for the sidebar mark, `PullRequestStatus` is the real gate on
/// the merge button and carries `canMerge`, `blockedReason` and `remedy`, `DeliveryHold` gates
/// whether a message may go, and `WorkspaceSafetyReport` gates archiving. A type that unified them
/// would be a fifth place to drift out of step with the four. So this calls them and emits their
/// answers verbatim, sentences included, rather than restating any of their reasoning.
///
/// ## Owner only, for now
///
/// A parent could reasonably be shown the workspaces it started, and `store.workspaces(startedBy:)`
/// makes that one query. It is still owner only, and the reason is `workspace_start`'s own
/// closing instruction: "There is no way to wait for it from here, so do not ask for one and then
/// sit idle." Handing a parent a cheap status call is handing it a polling loop, and the answer
/// the parked design gives to that question is a report the child files rather than a status the
/// parent watches. There is no reason of cost or of secrecy, so the parent case is a thing to add
/// once the report half exists, not a thing that was refused.
///
/// A child sees nothing here for the reason it sees nothing anywhere: it reports and that is all.
public struct WorkspaceListTool: BridgeToolHandling {
    public init() {}

    public let roles: Set<BridgeRole> = [.owner]

    public let tool = BridgeTool(
        name: "workspace_list",
        description: """
            The workspaces Bloom has: what each one is, what state it is in, and where its \
            worktree is on disk. This is how you find out what became of a workspace you \
            started, since workspace_start answers before any work happens and nothing waits \
            for it.

            Each one carries its id, name, branch, base branch and worktree path, its project, \
            whether it is active or archived, how far its setup script got, whether an agent is \
            running in it, whether one has stopped on a permission question and what it asked, \
            whether there is output nobody has read, the size of its diff, who asked for it, its \
            chats with their cost and context size, and any messages queued for those chats with \
            the reason the queue is not moving.

            The worktree path is the most useful thing here. It is an ordinary git checkout, so \
            read the diff, the log and the files in it with your own tools rather than asking \
            Bloom for them.

            By default it reads Bloom's database and nothing else, and at that price GitHub is \
            not consulted at all: there is no pull request, no checks, and the status can never \
            say merged, closed, draft or anything about checks. A default call has not looked, so \
            do not report that a workspace has no pull request on the strength of one. Pass \
            include_github to ask, which costs one gh call and one git call per workspace and is \
            slow on a long list.

            The diff counts and the states come from Bloom's database, which a running Bloom \
            refreshes every few seconds. With Bloom closed they are as old as the last time it \
            was open. Read only. It changes nothing and starts nothing.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "project": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Narrow it to one project, by the name or the path project_list reports. "
                            + "Leave it out for every project."
                    ),
                ]),
                "include_archived": .object([
                    "type": .string("boolean"),
                    "description": .string(
                        "Include workspaces that have been archived. They have no worktree left "
                            + "on disk. Off by default."
                    ),
                ]),
                "include_github": .object([
                    "type": .string("boolean"),
                    "description": .string(
                        "Include pull request and check state. Costs one gh call and one git "
                            + "call per workspace, so it is slow on a long list. Off by default."
                    ),
                ]),
            ]),
            "required": .array([]),
        ])
    )

    public func call(
        _ request: MCPRequest,
        as identity: BridgeIdentity,
        store: Store
    ) async -> BridgeToolResult {
        let includeArchived = request.param("include_archived")?.boolValue ?? false
        let includeGitHub = request.param("include_github")?.boolValue ?? false

        do {
            let projects = try await store.repos()
            var project: Repo?

            if let named = named(request) {
                let outcome = BridgeProjectLookup.find(named, in: projects)
                if let refusal = BridgeProjectLookup.refusal(
                    for: named, outcome: outcome, projects: projects
                ) {
                    return .failure(refusal)
                }
                guard case .found(let found) = outcome else {
                    return .failure("Bloom has no project called '\(named)'.")
                }
                project = found
            }

            let workspaces: [Workspace]
            if let project {
                workspaces = try await store.workspaces(
                    repoID: project.id, includeArchived: includeArchived
                )
            } else {
                workspaces = try await store.workspaces(includeArchived: includeArchived)
            }

            let names = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
            var rows: [JSONValue] = []
            for workspace in workspaces {
                rows.append(await row(
                    for: workspace,
                    project: names[workspace.repoID],
                    includeGitHub: includeGitHub,
                    store: store
                ))
            }

            return .json(.object([
                "workspaces": .array(rows),
                "count": .integer(rows.count),
                "note": .string(note(
                    count: rows.count,
                    project: project,
                    includeArchived: includeArchived,
                    includeGitHub: includeGitHub
                )),
            ]))
        } catch {
            return .failure("Bloom could not read its workspaces: \(error.readableMessage)")
        }
    }

    /// What the answer says about itself.
    ///
    /// The point of it is the second half. A model that called this without `include_github` and
    /// then told the owner "none of them have a pull request" would be reporting the absence of a
    /// question as the absence of an answer, which is the same failure `FolderRefusal.agentSentence` heads
    /// off in its own register. So the shape of the answer says what was not asked.
    private func note(
        count: Int,
        project: Repo?,
        includeArchived: Bool,
        includeGitHub: Bool
    ) -> String {
        var sentences: [String] = []

        if count == 0 {
            sentences.append(
                project.map { "Bloom has no workspaces in '\($0.name)'." }
                    ?? "Bloom has no workspaces."
            )
            if !includeArchived {
                sentences.append("Archived ones were not counted. Pass include_archived to see them.")
            }
        } else if !includeArchived {
            sentences.append("Archived workspaces are not in this list.")
        }

        sentences.append(
            includeGitHub
                ? "GitHub was asked about every workspace with a worktree still on disk. A "
                    + "workspace with no pull_request has no pull request for its branch, or gh "
                    + "is not installed or not signed in."
                : "GitHub was not asked, so nothing here says anything about pull requests or "
                    + "checks, and status cannot report either. Pass include_github to ask."
        )

        return sentences.joined(separator: " ")
    }

    private func named(_ request: MCPRequest) -> String? {
        guard let text = request.stringParam("project") else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: One workspace

    private func row(
        for workspace: Workspace,
        project: Repo?,
        includeGitHub: Bool,
        store: Store
    ) async -> JSONValue {
        let sessions = (try? await store.sessions(workspaceID: workspace.id)) ?? []
        // The session state column, not a live process, and that is the honest source: the runner
        // writes it on every change, and `Store.resetRunningSessions` clears it at launch so a row
        // left `running` by a crash cannot claim an agent that is long gone.
        let isRunning = sessions.contains { $0.state == .running }
        let isAwaiting = sessions.contains { $0.state == .waiting }

        let pullRequest = includeGitHub ? await self.pullRequest(for: workspace) : nil
        let status = WorkspaceStatus.resolve(
            workspace: workspace,
            isRunning: isRunning,
            pullRequest: pullRequest,
            isAwaitingPermission: isAwaiting
        )

        var sessionRows: [JSONValue] = []
        var queued = 0
        for session in sessions {
            let asks = (try? await store.pendingPermissionAsks(sessionID: session.id)) ?? []
            let pending = (try? await store.pendingDeliveries(sessionID: session.id)) ?? []
            queued += pending.count
            sessionRows.append(self.row(
                for: session, in: workspace, asks: asks, pending: pending.count
            ))
        }

        var answer: [String: JSONValue] = [
            "id": .string(workspace.id.rawValue),
            "name": .string(workspace.name),
            "branch": .string(workspace.branch),
            "base_branch": .string(workspace.baseBranch),
            "path": .string(workspace.path),
            "state": .string(workspace.state.rawValue),
            "setup_state": .string(workspace.setupState.rawValue),
            // `WorkspaceStatus`'s own word and its own label, not a second vocabulary beside them.
            "status": .string(status.rawValue),
            "status_label": .string(status.label),
            "agent_running": .bool(isRunning),
            "awaiting_permission": .bool(isAwaiting),
            "unread": .bool(workspace.unread),
            "diff": .object([
                "additions": .integer(workspace.additions),
                "deletions": .integer(workspace.deletions),
                "changed_files": .integer(workspace.changedFiles),
            ]),
            "sessions": .array(sessionRows),
            "queued_messages": .integer(queued),
            "created_at": .string(workspace.createdAt.formatted(.iso8601)),
            "last_activity_at": .string(workspace.lastActivityAt.formatted(.iso8601)),
        ]

        if let project {
            answer["project"] = .object([
                "id": .string(project.id.rawValue),
                "name": .string(project.name),
                "path": .string(project.path),
            ])
        }

        // The same shape whoami emits, so the two tools describe parentage in one vocabulary.
        switch workspace.origin {
        case .user, .ownerClient:
            answer["created_by"] = .string("owner")
        case .agent(let parentWorkspaceID, let spawnToolUseID):
            answer["created_by"] = .object([
                "agent_in_workspace": .string(parentWorkspaceID.rawValue),
                "spawn_tool_use_id": .string(spawnToolUseID),
            ])
        }

        if let pullRequest {
            answer["pull_request"] = await self.row(
                for: pullRequest, in: workspace
            )
        }

        return .object(answer)
    }

    private func row(
        for session: Session,
        in workspace: Workspace,
        asks: [PendingPermissionAsk],
        pending: Int
    ) -> JSONValue {
        // Quoted from `DeliveryHold`, which is the gate the composer and the drain both ask, so a
        // caller reading this and a person looking at the transcript are told the same thing in
        // the same words.
        let hold = DeliveryHold.of(
            isRunningSetup: workspace.setupState == .running,
            didSetupFail: workspace.setupState == .failed,
            isTurnRunning: session.state == .running,
            isAwaitingQuestion: session.state == .waiting
        )

        var answer: [String: JSONValue] = [
            "id": .string(session.id.rawValue),
            "title": .string(session.title),
            "agent": .string(session.agentKind.rawValue),
            "state": .string(session.state.rawValue),
            "cost_usd": .number(session.costUSD),
            "context_tokens": .integer(session.contextTokens),
            "queued_messages": .integer(pending),
            "hold_note": .string(hold.sentence),
        ]

        if !asks.isEmpty {
            answer["questions"] = .array(asks.map {
                .object([
                    "tool": .string($0.ask.label),
                    "summary": .string($0.ask.summary),
                ])
            })
        }

        return .object(answer)
    }

    // MARK: What GitHub knows

    /// Nil for every reason at once: gh missing, signed out, no pull request for the branch, or a
    /// worktree that has been archived away. None of those is worth failing the whole listing
    /// over, so the workspace falls back to what Bloom's own database can say about it.
    private func pullRequest(for workspace: Workspace) async -> PullRequest? {
        guard FileManager.default.fileExists(atPath: workspace.path) else { return nil }
        return try? await GitHub.pullRequest(for: workspace, maxAge: .seconds(60))
    }

    /// The pull request block, which is `PullRequestStatus` read out loud.
    ///
    /// `status(local:)` and not `status`, and the difference is the whole reason the local counts
    /// are fetched. Every state GitHub reports describes the commit that was pushed, so "Ready to
    /// merge" over a worktree holding uncommitted work is not a stale answer but a wrong one, and
    /// weighing the local work against it is what turns that headline into "Local changes" with a
    /// remedy of push or commitAndPush. A caller told the unweighed answer would report a branch
    /// as finished while the work was still on this disk.
    private func row(for pullRequest: PullRequest, in workspace: Workspace) async -> JSONValue {
        let local = try? await Git.localWork(worktree: workspace.path)
        let status = pullRequest.status(local: local)

        var answer: [String: JSONValue] = [
            "number": .integer(pullRequest.number),
            "url": .string(pullRequest.url),
            "state": .string(pullRequest.state),
            "draft": .bool(pullRequest.isDraft),
            "checks": .string(pullRequest.checks.rawValue),
            "checks_summary": .string(pullRequest.checksSummary),
            // Verbatim from `PullRequestStatus`, which is the gate the merge button asks. Nothing
            // here is re-derived, so a caller and the button cannot disagree about a branch.
            "headline": .string(status.text),
            "can_merge": .bool(status.canMerge),
            "blocked_reason": status.blockedReason.map(JSONValue.string) ?? .null,
            "remedy": .string(remedy(status.remedy)),
        ]

        if let detail = status.detail, !detail.isEmpty {
            answer["detail"] = .string(detail)
        }

        if let local {
            answer["local"] = .object([
                "files_to_commit": .integer(local.modifiedFiles + local.untrackedFiles),
                "commits_to_push": .integer(local.hasUnpushed ? local.unpushedCommits : 0),
            ])
        }

        return .object(answer)
    }

    /// `Remedy` has no raw value, because in the app it decides a button's label rather than a
    /// word. Named here rather than given one, so adding a case is a compile error in this file
    /// instead of a string nobody chose leaking onto the wire.
    private func remedy(_ remedy: PullRequestStatus.Remedy) -> String {
        switch remedy {
        case .merge: "merge"
        case .push: "push"
        case .commitAndPush: "commitAndPush"
        case .fixConflicts: "fixConflicts"
        }
    }
}
