import Testing
import Foundation
@testable import BloomCore

/// A pull request that has been merged and had its branch deleted, which is the state Bloom's own
/// merge leaves a workspace in and the state every lookup it had used to fail in.
///
/// The report: a review of pull request #222 in `spatie/laravel-csp` was squashed and the branch
/// went on both sides. Bloom's band went on showing it as open and ready to merge, with eighteen
/// checks passed and a live Squash and merge button, for the rest of the launch. GitHub had
/// already landed it.
///
/// Measured in that worktree, running exactly what Bloom runs:
///
///     gh pr view sentry-worker-src-blob   ->  no pull requests found for branch
///     gh pr view                          ->  no pull requests found for branch "main"
///     gh pr view 222                      ->  {"state":"MERGED","mergedAt":"..."}
///
/// A number survives the branch and a branch name does not. These tests are the rules that
/// follow from that: which number to write down, which of several pull requests wearing one
/// reused head name is this workspace's, and that the column holding the number behaves like
/// every other column in `Store`.
@Suite("A merged pull request whose branch is gone", .tags(.persistence), .scratchDirectory)
struct MergedPullRequestTests {
    private func pullRequest(number: Int, state: String = "MERGED") -> PullRequest {
        PullRequest(
            number: number,
            title: "Read the Sentry worker from a blob",
            url: "https://github.com/spatie/laravel-csp/pull/\(number)",
            state: state,
            branch: "sentry-worker-src-blob",
            closedAt: state == "OPEN" ? nil : Date()
        )
    }

    private func seed(_ store: Store, name: String = "review") async throws -> Workspace {
        let repo = try await store.upsert(Repo(name: name, path: TestScratch.unique("repo")))
        return try await store.upsert(Workspace(
            repoID: repo.id, name: name, branch: "sentry-worker-src-blob",
            path: TestScratch.unique("worktree"), baseBranch: "main"
        ))
    }

    // MARK: - Which number is worth writing down

    @Test("the first answer about a workspace is written down")
    func recordsTheFirstAnswer() {
        #expect(PullRequestNumber.toRecord(found: pullRequest(number: 222), recorded: nil) == 222)
    }

    @Test("an answer the row already holds is not written again")
    func skipsAnUnchangedNumber() {
        // Otherwise every poll rewrites the row, the WAL grows and everything observing the store
        // reloads for a change that is not one. The same reasoning as `updateDiffStat`.
        #expect(PullRequestNumber.toRecord(found: pullRequest(number: 222), recorded: 222) == nil)
    }

    @Test("a newer pull request replaces the one on the row")
    func newestAnswerWins() {
        // An agent that merges, cuts a fresh branch and opens a second pull request leaves the row
        // naming the first. A row that names a merged pull request forever is the reported bug one
        // launch later, arriving from the other direction.
        #expect(
            PullRequestNumber.toRecord(found: pullRequest(number: 223, state: "OPEN"), recorded: 222)
                == 223
        )
    }

    @Test("nothing is written when the lookup answered nothing")
    func keepsTheNumberWhenGHCannotAnswer() {
        // Nil is "gh could not answer" at least as often as it is "there is no pull request", and
        // clearing an exact number on the strength of a slow network throws away the one fact
        // that survives a relaunch.
        #expect(PullRequestNumber.toRecord(found: nil, recorded: 222) == nil)
    }

    @Test("a payload with no number in it is not written down as pull request zero")
    func refusesZero() throws {
        // A gh old enough not to report `number` decodes as 0, and a 0 on the row would be asked
        // about with `gh pr view 0` on every poll for the rest of that workspace's life.
        let decoded = try GitHub.decodePullRequest(from: Data("""
        {"state":"MERGED","headRefName":"sentry-worker-src-blob"}
        """.utf8))
        #expect(decoded.number == 0)
        #expect(PullRequestNumber.toRecord(found: decoded, recorded: nil) == nil)
    }

    // MARK: - Choosing between pull requests that shared a head name

    private let started = Date(timeIntervalSince1970: 2_000_000)

    @Test("the newest pull request that could be this workspace's is chosen")
    func choosesTheNewestPlausibleMatch() {
        // `gh pr list --head patch-2 --state all` in the repository this was reported from answers
        // with three, from three different people, spread over years. Searching by a head that has
        // been deleted is the one lookup that can come back with more than one.
        let matches = [
            PullRequestHeadMatch(number: 11, closedAt: started.addingTimeInterval(-604_800)),
            PullRequestHeadMatch(number: 175, closedAt: started.addingTimeInterval(3_600)),
            PullRequestHeadMatch(number: 207, closedAt: started.addingTimeInterval(-86_400)),
        ]
        #expect(
            PullRequestOwnership.choose(from: matches, startedAt: started, checkedOutAs: nil) == 175
        )
    }

    @Test("a pull request that ended before the workspace existed is not chosen")
    func refusesAnEarlierLifeOfTheName() {
        let matches = [PullRequestHeadMatch(number: 371, closedAt: started.addingTimeInterval(-86_400))]
        #expect(
            PullRequestOwnership.choose(from: matches, startedAt: started, checkedOutAs: nil) == nil
        )
    }

    @Test("an open one is chosen whenever the workspace was created")
    func acceptsAnOpenMatch() {
        let matches = [PullRequestHeadMatch(number: 412, closedAt: nil)]
        #expect(
            PullRequestOwnership.choose(from: matches, startedAt: started, checkedOutAs: nil) == 412
        )
    }

    @Test("what the worktree was checked out from outranks the dates")
    func keepsTheCheckedOutNumber() {
        // Reviewing something that landed last week is done on purpose, and the dates alone would
        // refuse it. This is the same precedence `belongs` has.
        let matches = [PullRequestHeadMatch(number: 222, closedAt: started.addingTimeInterval(-604_800))]
        #expect(
            PullRequestOwnership.choose(from: matches, startedAt: started, checkedOutAs: 222) == 222
        )
        #expect(
            PullRequestOwnership.choose(from: matches, startedAt: started, checkedOutAs: 900) == nil
        )
    }

    @Test("nothing to choose from is nothing chosen")
    func choosesNothingFromAnEmptySearch() {
        #expect(PullRequestOwnership.choose(from: [], startedAt: started, checkedOutAs: nil) == nil)
    }

    // MARK: - A number gh could never be asked about

    @Test("a number that is not a number is never handed to gh")
    func refusesToAskAboutANonPositiveNumber() async {
        // gh reads its positional argument with the same parser it uses for flags, which is why
        // the branch route validates the name first. A positive Int renders as digits with no
        // leading `-`, so the guard is what makes that true of this route too. No worktree exists
        // at the path below, so anything that did reach a subprocess would fail rather than pass.
        #expect(await GitHub.snapshot(forNumber: 0, worktree: "/nowhere", maxAge: .zero) == nil)
        #expect(await GitHub.snapshot(forNumber: -1, worktree: "/nowhere", maxAge: .zero) == nil)
    }

    // MARK: - The column

    @Test("the number is written, read back, and survives a relaunch")
    func theNumberSurvivesARelaunch() async throws {
        let path = TestScratch.unique("pr-number-restart") + ".sqlite"
        let store = try Store(path: path)
        let workspace = try await seed(store)
        #expect(workspace.pullRequestNumber == nil)

        await PullRequestNumber.record(pullRequest(number: 222), for: workspace, in: store)

        // The relaunch is the whole point: in memory the number was there all along, and the bug
        // it fixes outlives the launch it was found in.
        let relaunched = try Store(path: path)
        #expect(try await relaunched.workspace(id: workspace.id)?.pullRequestNumber == 222)
    }

    @Test("recording the number leaves alone every column it did not name")
    func recordingIsANarrowWrite() async throws {
        let store = try makeTestStore("pr-number-isolation")
        let workspace = try await seed(store)

        // Everything below happens after the caller's copy was read, which is what a `gh` round
        // trip guarantees: it takes seconds, and the diff stat refresh runs every six.
        try await store.updateDiffStat(workspaceID: workspace.id, additions: 9, deletions: 2, files: 3)
        try await store.update(workspaceID: workspace.id) { $0.pinned = true }
        try await store.recordPullRequestNumber(222, workspaceID: workspace.id)

        let stored = try #require(try await store.workspace(id: workspace.id))
        #expect(stored.pullRequestNumber == 222)
        #expect(stored.additions == 9)
        #expect(stored.pinned)
    }

    @Test("the other writers of a workspace row leave the number alone")
    func writersKeepTheNumber() async throws {
        let store = try makeTestStore("pr-number-writers")
        let workspace = try await seed(store)
        try await store.recordPullRequestNumber(222, workspaceID: workspace.id)

        try await store.updateDiffStat(workspaceID: workspace.id, additions: 1, deletions: 0, files: 1)
        try await store.touch(workspaceID: workspace.id, unread: true)
        try await store.update(workspaceID: workspace.id) { $0.pinned = true }
        try await store.update(workspaceID: workspace.id) { $0.archive() }

        #expect(try await store.workspace(id: workspace.id)?.pullRequestNumber == 222)
    }

    @Test("a row written before the column existed reads as knowing no pull request")
    func anExistingDatabaseMigrates() async throws {
        let path = TestScratch.unique("pr-number-migration") + ".sqlite"
        let store = try Store(path: path)
        let workspace = try await seed(store)
        try await store.recordPullRequestNumber(222, workspaceID: workspace.id)

        // `ALTER TABLE` has no `IF NOT EXISTS`, and this is the shape the store's own tests use to
        // reproduce an old schema: replaying the step must neither throw nor clear the column.
        let raw = try SQLiteDatabase(path: path)
        raw.userVersion = 0

        let reopened = try Store(path: path)
        #expect(try await reopened.workspace(id: workspace.id)?.pullRequestNumber == 222)

        // And a row nothing has answered about yet is nil rather than pull request zero.
        let fresh = try await seed(reopened, name: "fresh")
        #expect(fresh.pullRequestNumber == nil)
    }

    // MARK: - Where the number comes from at creation

    @Test("a workspace opened on a pull request knows its number before anything is looked up")
    func aReviewWorkspaceCarriesItsNumber() {
        let listing = PullRequestListing(
            number: 222,
            title: "Read the Sentry worker from a blob",
            headRefName: "sentry-worker-src-blob",
            baseRefName: "main"
        )
        #expect(WorkspaceCheckout.pullRequest(listing).pullRequestNumber == 222)

        // Opening a branch says nothing about a pull request, which is not the same as a pull
        // request whose number is not known yet. The column stays nil and a lookup fills it in.
        let branch = ExistingBranch(name: "sentry-worker-src-blob", isLocal: true)
        #expect(WorkspaceCheckout.branch(branch).pullRequestNumber == nil)
    }
}
