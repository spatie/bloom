import Foundation

/// One reading of the workspaces, for the two tools that describe them to a model.
///
/// # The bug this was written for
///
/// An agent on the owner's bridge said, in one conversation, "four of them with a workspace
/// running" and then, a few calls later, "workspace_list and project_list disagree: the former
/// shows no workspace for livewire-filepond, the latter says both have one". Neither tool was
/// reading the wrong rows. `project_list` counted `state != .archived` and published the number
/// under the key **`workspaces_running`**, with a description promising "how many workspaces it
/// has running" and `docs/BRIDGE.md` calling it a "live workspace count". Three names for a count
/// of workspaces that merely **exist**, and a model that believed any of them then read
/// `workspace_list`, found `agent_running: false` on every row, and reported the contradiction it
/// had been handed. The sidebar agreed with `workspace_list` throughout, because the sidebar never
/// claimed anything was running either.
///
/// So the fix is not a query. Both tools already read the same table through the same
/// `state = 'active'` predicate and could not disagree about which workspaces exist. The fix is
/// that "how many workspaces" and "how many have an agent in them" are two numbers, both of them
/// worth answering, and neither of them may be published under the other's name.
///
/// # Why one type rather than two counts
///
/// A count in `project_list` and a flag in `workspace_list` derived separately are two rules to
/// drift, which is the same argument `AgentTurns` itself makes about the three answers the app
/// used to have to "is an agent running here". This holds one reading of the workspaces and one
/// reading of the session rows, and both tools answer from it: `project_list`'s
/// `agents_running` for a project is exactly the number of that project's rows on which
/// `workspace_list` prints `agent_running: true`.
///
/// Two queries, whatever is asked of it. `Store.sessionActivity` is three columns of the rows that
/// are mid turn or blocked rather than every session in the database, so `project_list` stays the
/// cheap call its description promises rather than becoming one query per workspace.
public struct BridgeWorkspaceCensus: Sendable {
    /// What one project holds, in the three numbers a caller acts on.
    ///
    /// `workspaces` and `agentsRunning` are separate fields rather than one summarised number
    /// because collapsing them is the bug above. `awaitingPermission` is here for the same reason
    /// in the other direction: a project whose only agent is stopped on a question reports
    /// `agentsRunning: 0`, and a caller told nothing else would read that as "nothing is
    /// happening" when what it means is "you are the thing that is not happening".
    public struct Counts: Sendable, Hashable {
        /// Workspaces this project has that are not archived, whether or not anything is
        /// happening in them. The number of rows the sidebar draws under the project.
        public var workspaces: Int
        /// How many of those have an agent mid turn.
        public var agentsRunning: Int
        /// How many of those have an agent stopped on a permission question.
        public var awaitingPermission: Int

        public init(workspaces: Int = 0, agentsRunning: Int = 0, awaitingPermission: Int = 0) {
            self.workspaces = workspaces
            self.agentsRunning = agentsRunning
            self.awaitingPermission = awaitingPermission
        }
    }

    /// Every workspace, archived ones included, in the order the store hands them back. Archived
    /// rows are kept rather than filtered here because `workspace_list` can be asked for them and
    /// a second reading to find them would be a second reading to disagree with this one.
    public let all: [Workspace]

    private let running: Set<WorkspaceID>
    private let awaiting: Set<WorkspaceID>

    public init(all: [Workspace], running: Set<WorkspaceID>, awaitingPermission: Set<WorkspaceID>) {
        self.all = all
        self.running = running
        self.awaiting = awaitingPermission
    }

    /// One reading of the database, for whichever tool asked.
    ///
    /// The two questions are asked of `AgentTurns` rather than of the session states directly, so
    /// this and the sidebar's mark cannot come to different conclusions about what a running agent
    /// is. `live` is empty because nothing here is the window: the bridge is served from the core
    /// and has no transcripts to consult, and the stored row is the durable trace the runner
    /// writes on every move it makes. That is the same half `WorkspaceLookup` reads for Shortcuts,
    /// and it is why `Store.resetRunningSessions` exists: a row left `running` by a crash cannot
    /// claim an agent that is long gone.
    public static func read(from store: Store) async throws -> BridgeWorkspaceCensus {
        let all = try await store.workspaces(includeArchived: true)
        let activity = try await store.sessionActivity()
        return BridgeWorkspaceCensus(
            all: all,
            running: AgentTurns.workspaces(.running, stored: activity, live: []),
            awaitingPermission: AgentTurns.workspaces(
                .awaitingPermission, stored: activity, live: []
            )
        )
    }

    /// The rows a listing draws, narrowed the two ways `workspace_list` can narrow them.
    ///
    /// Filtering the whole list keeps the store's `sort_order, created_at` ordering within each
    /// project, which is what a per-project query would have returned anyway.
    public func listing(repoID: RepoID? = nil, includeArchived: Bool = false) -> [Workspace] {
        all.filter { workspace in
            if let repoID, workspace.repoID != repoID { return false }
            return includeArchived || workspace.state != .archived
        }
    }

    /// Whether an agent is mid turn in this workspace.
    public func isRunning(_ workspaceID: WorkspaceID) -> Bool { running.contains(workspaceID) }

    /// Whether an agent in this workspace has stopped and cannot go on until somebody answers.
    public func isAwaitingPermission(_ workspaceID: WorkspaceID) -> Bool {
        awaiting.contains(workspaceID)
    }

    /// What one project holds. Archived workspaces are counted in none of the three: they have no
    /// worktree left on disk and nothing can be running in one.
    public func counts(repoID: RepoID) -> Counts {
        let rows = listing(repoID: repoID)
        return Counts(
            workspaces: rows.count,
            agentsRunning: rows.count { isRunning($0.id) },
            awaitingPermission: rows.count { isAwaitingPermission($0.id) }
        )
    }
}
