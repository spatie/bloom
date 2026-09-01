import Foundation
import Testing
@testable import BloomCore

/// The one reading `project_list` and `workspace_list` both answer from.
///
/// The counting half is tested without a store, because it is arithmetic over three sets and a
/// list, and the reading half is tested against a real one, because what it has to get right is
/// which rows a query hands back.
@Suite("BridgeWorkspaceCensus", .tags(.persistence), .scratchDirectory)
struct BridgeWorkspaceCensusTests {
    private let repo = RepoID("repo-1")
    private let other = RepoID("repo-2")

    private func workspace(
        _ name: String, in repoID: RepoID, state: WorkspaceState = .active
    ) -> Workspace {
        Workspace(
            repoID: repoID,
            name: name,
            branch: "claude/\(name)",
            path: "/tmp/worktrees/\(name)",
            baseBranch: "main",
            state: state
        )
    }

    // MARK: The counting

    /// The bug, stated as an assertion. A workspace nobody has archived and nobody is working in
    /// counts as a workspace and does not count as an agent running, and no single number can be
    /// asked to mean both.
    @Test("a workspace that exists is counted, and is not counted as an agent running")
    func existingIsNotRunning() {
        let idle = workspace("idle", in: repo)
        let census = BridgeWorkspaceCensus(
            all: [idle], running: [], awaitingPermission: []
        )

        let counts = census.counts(repoID: repo)

        #expect(counts.workspaces == 1)
        #expect(counts.agentsRunning == 0)
        #expect(counts.awaitingPermission == 0)
        #expect(!census.isRunning(idle.id))
    }

    /// An agent stopped on a question is not running and is not nothing, and a caller told only
    /// `agents_running: 0` would read the project as quiet when it is waiting on the owner.
    @Test("an agent stopped on a question is counted apart from one that is working")
    func blockedIsItsOwnNumber() {
        let working = workspace("working", in: repo)
        let blocked = workspace("blocked", in: repo)
        let census = BridgeWorkspaceCensus(
            all: [working, blocked],
            running: [working.id],
            awaitingPermission: [blocked.id]
        )

        let counts = census.counts(repoID: repo)

        #expect(counts.workspaces == 2)
        #expect(counts.agentsRunning == 1)
        #expect(counts.awaitingPermission == 1)
    }

    @Test("archived workspaces are counted in none of the three")
    func archivedIsCountedNowhere() {
        let live = workspace("live", in: repo)
        let gone = workspace("gone", in: repo, state: .archived)
        let census = BridgeWorkspaceCensus(
            all: [live, gone], running: [live.id, gone.id], awaitingPermission: []
        )

        #expect(census.counts(repoID: repo).workspaces == 1)
        #expect(census.counts(repoID: repo).agentsRunning == 1)
        #expect(census.listing(repoID: repo).map(\.name) == ["live"])
        #expect(census.listing(repoID: repo, includeArchived: true).map(\.name) == ["live", "gone"])
    }

    @Test("a project is counted over its own workspaces and no others")
    func countsAreScopedToTheProject() {
        let mine = workspace("mine", in: repo)
        let theirs = workspace("theirs", in: other)
        let census = BridgeWorkspaceCensus(
            all: [mine, theirs], running: [theirs.id], awaitingPermission: []
        )

        #expect(census.counts(repoID: repo).workspaces == 1)
        #expect(census.counts(repoID: repo).agentsRunning == 0)
        #expect(census.counts(repoID: other).agentsRunning == 1)
    }

    /// The property the two tools rest on: whatever the census counts for a project, it can also
    /// name, so a count and a listing taken from one census cannot disagree about how many there
    /// are.
    @Test("a project's count is the length of that project's listing")
    func theCountIsTheListing() {
        let census = BridgeWorkspaceCensus(
            all: [
                workspace("a", in: repo),
                workspace("b", in: repo, state: .archived),
                workspace("c", in: other),
            ],
            running: [],
            awaitingPermission: []
        )

        for repoID in [repo, other] {
            #expect(census.counts(repoID: repoID).workspaces == census.listing(repoID: repoID).count)
        }
    }

    // MARK: The reading

    @Test("it reads the running and blocked workspaces out of the session rows")
    func readsTheStore() async throws {
        let store = try makeTestStore("census-read")
        let project = try await store.upsert(
            Repo(name: "flare", path: "/tmp/flare", defaultBranch: "main")
        )
        let idle = try await store.upsert(Workspace(
            repoID: project.id, name: "idle", branch: "b1", path: "/tmp/w1", baseBranch: "main"
        ))
        let working = try await store.upsert(Workspace(
            repoID: project.id, name: "working", branch: "b2", path: "/tmp/w2", baseBranch: "main"
        ))
        var turn = Session(workspaceID: working.id, title: "First chat")
        turn.apply(.turnStarted)
        _ = try await store.upsert(turn)

        let blocked = try await store.upsert(Workspace(
            repoID: project.id, name: "blocked", branch: "b3", path: "/tmp/w3", baseBranch: "main"
        ))
        var question = Session(workspaceID: blocked.id, title: "First chat")
        question.apply(.turnStarted)
        question.apply(.blocked)
        _ = try await store.upsert(question)

        let census = try await BridgeWorkspaceCensus.read(from: store)
        let counts = census.counts(repoID: project.id)

        #expect(counts.workspaces == 3)
        #expect(counts.agentsRunning == 1)
        #expect(counts.awaitingPermission == 1)
        #expect(census.isRunning(working.id))
        #expect(!census.isRunning(idle.id))
        #expect(!census.isRunning(blocked.id))
        #expect(census.isAwaitingPermission(blocked.id))
    }

    /// An idle chat is a chat, and a workspace that has been talked to and is not being talked to
    /// now is the ordinary case. Counting sessions rather than turns would report it as busy for
    /// the rest of its life.
    @Test("a workspace whose chats are all idle is running nothing")
    func anIdleChatIsNotATurn() async throws {
        let store = try makeTestStore("census-idle")
        let project = try await store.upsert(
            Repo(name: "flare", path: "/tmp/flare", defaultBranch: "main")
        )
        let workspace = try await store.upsert(Workspace(
            repoID: project.id, name: "spoken to", branch: "b", path: "/tmp/w", baseBranch: "main"
        ))
        var session = Session(workspaceID: workspace.id, title: "First chat")
        session.apply(.turnStarted)
        session.apply(.turnFinished(isError: false))
        _ = try await store.upsert(session)

        let census = try await BridgeWorkspaceCensus.read(from: store)

        #expect(census.counts(repoID: project.id).workspaces == 1)
        #expect(census.counts(repoID: project.id).agentsRunning == 0)
    }
}
