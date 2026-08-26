import Foundation
import Testing
@testable import BloomCore

/// The decisions behind opening a workspace on something that already exists: which pull requests
/// are offered, what a pasted URL means, what the branch and the workspace end up called, and what
/// the diff is measured against.
@Suite("Workspace checkout")
struct WorkspaceCheckoutTests {
    private func listing(
        number: Int = 12,
        title: String = "Fix the parser",
        head: String = "fix-parser",
        base: String = "main",
        state: String = "OPEN",
        isDraft: Bool = false,
        fork: Bool = false,
        owner: String? = nil
    ) -> PullRequestListing {
        PullRequestListing(
            number: number,
            title: title,
            author: "contributor",
            headRefName: head,
            baseRefName: base,
            isDraft: isDraft,
            state: state,
            isCrossRepository: fork,
            headRepositoryOwner: owner
        )
    }

    // MARK: - What is offered

    @Test("Open pull requests are offered newest first")
    func offersOpenNewestFirst() {
        let offered = WorkspaceCheckoutPlan.offered([
            listing(number: 3), listing(number: 9), listing(number: 5),
        ])
        #expect(offered.map(\.number) == [9, 5, 3])
    }

    @Test("Closed and merged pull requests are not offered")
    func skipsClosedAndMerged() {
        let offered = WorkspaceCheckoutPlan.offered([
            listing(number: 1, state: "MERGED"),
            listing(number: 2, state: "CLOSED"),
            listing(number: 3, state: "OPEN"),
        ])
        #expect(offered.map(\.number) == [3])
    }

    @Test("A draft is offered, because a draft is exactly what gets pulled down to look at")
    func offersDrafts() {
        #expect(WorkspaceCheckoutPlan.offered([listing(isDraft: true)]).count == 1)
    }

    @Test("The list is capped, so a busy repository does not fill the screen")
    func capsTheList() {
        let many = (1...80).map { listing(number: $0) }
        #expect(WorkspaceCheckoutPlan.offered(many, limit: 5).map(\.number) == [80, 79, 78, 77, 76])
    }

    // MARK: - Branches

    @Test("Local and remote branches merge into one list, the local copy winning")
    func mergesBranches() {
        let branches = WorkspaceCheckoutPlan.offeredBranches(
            local: ["main", "wip"],
            remote: ["origin/main", "origin/wip", "origin/theirs", "origin/HEAD"],
            defaultBranch: "main"
        )
        #expect(branches.map(\.name) == ["theirs", "wip"])
        #expect(branches.first { $0.name == "wip" }?.isLocal == true)
        #expect(branches.first { $0.name == "theirs" }?.isLocal == false)
    }

    @Test("A branch a workspace is already on is still offered, wearing the workspace's name")
    func marksBranchesInUse() {
        // It used to be dropped, because git refuses one branch in two worktrees. That answered
        // "where is the branch I was working on yesterday" with silence. The row is offered and
        // marked instead; selecting it goes to the workspace rather than creating a second one.
        let branches = WorkspaceCheckoutPlan.offeredBranches(
            local: ["main", "wip", "review"],
            remote: [],
            defaultBranch: "main",
            inUse: ["review": .workspace("Quiet Harbour")]
        )
        #expect(branches.map(\.name) == ["review", "wip"])
        #expect(branches.first { $0.name == "review" }?.inUseBy == .workspace("Quiet Harbour"))
        #expect(branches.first { $0.name == "wip" }?.inUseBy == nil)
    }

    /// What a caller naming a branch by name is looked up in. The picker drops the default branch
    /// because it is normally the one the project's own checkout is on, and normally is not always:
    /// a project left on a feature branch has its default free, and a list that hid it would refuse
    /// a checkout git would have allowed. Nothing is hidden here, and `inUse` answers instead.
    @Test("Every branch, for a caller that names one, keeps the default branch in the list")
    func keepsEverythingWhenNothingIsBeingOffered() {
        let branches = WorkspaceCheckoutPlan.everyBranch(
            local: ["main", "wip"],
            remote: ["origin/main", "origin/theirs", "origin/HEAD"],
            inUse: ["main": .projectCheckout(path: "/dev/flare")]
        )
        #expect(branches.map(\.name) == ["main", "theirs", "wip"])
        #expect(branches.first { $0.name == "main" }?.inUseBy == .projectCheckout(path: "/dev/flare"))
    }

    @Test("A head with a pull request open on it is offered as the pull request and not twice")
    func skipsBranchesWithAnOpenPullRequest() {
        let requests = [listing(number: 4, head: "figma-mcp-check")]
        let branches = WorkspaceCheckoutPlan.offeredBranches(
            local: ["main", "figma-mcp-check", "wip"],
            remote: ["origin/figma-mcp-check"],
            defaultBranch: "main",
            pullRequestHeads: WorkspaceCheckoutPlan.heads(of: requests)
        )
        #expect(branches.map(\.name) == ["wip"])
    }

    @Test("Being in use does not save a branch from the exclusions that are still right")
    func keepsExcludingWhatAPullRequestSpeaksFor() {
        let requests = [listing(number: 4, head: "figma-mcp-check")]
        let branches = WorkspaceCheckoutPlan.offeredBranches(
            local: ["main", "figma-mcp-check"],
            remote: ["origin/HEAD"],
            defaultBranch: "main",
            inUse: ["figma-mcp-check": .workspace("Coral Bay"), "main": .workspace("Coral Bay")],
            pullRequestHeads: WorkspaceCheckoutPlan.heads(of: requests)
        )
        #expect(branches.isEmpty)
    }

    @Test("A fork's head does not hide a branch of this repository that shares its name")
    func keepsBranchesSharingAForkHeadName() {
        let requests = [listing(number: 4, head: "patch-1", fork: true, owner: "someone")]
        #expect(WorkspaceCheckoutPlan.heads(of: requests).isEmpty)
        let branches = WorkspaceCheckoutPlan.offeredBranches(
            local: ["main", "patch-1"],
            remote: [],
            defaultBranch: "main",
            pullRequestHeads: WorkspaceCheckoutPlan.heads(of: requests)
        )
        #expect(branches.map(\.name) == ["patch-1"])
    }

    @Test("Only origin's branches count as remote branches")
    func readsRemoteNames() {
        #expect(WorkspaceCheckoutPlan.remoteBranchName("origin/feature/x") == "feature/x")
        #expect(WorkspaceCheckoutPlan.remoteBranchName("upstream/main") == nil)
        #expect(WorkspaceCheckoutPlan.remoteBranchName("origin/HEAD") == nil)
    }

    // MARK: - What was typed

    @Test("A bare number, with or without its hash, is a pull request")
    func parsesNumbers() {
        #expect(WorkspaceCheckoutPlan.parseReference("42") == PullRequestReference(number: 42))
        #expect(WorkspaceCheckoutPlan.parseReference(" #42 ") == PullRequestReference(number: 42))
    }

    @Test("A pull request URL carries its repository with it")
    func parsesURLs() {
        #expect(
            WorkspaceCheckoutPlan.parseReference("https://github.com/spatie/laravel-backup/pull/1234")
                == PullRequestReference(number: 1234, repository: "spatie/laravel-backup")
        )
        #expect(
            WorkspaceCheckoutPlan.parseReference("https://github.com/spatie/ray/pull/7/files#r12345")
                == PullRequestReference(number: 7, repository: "spatie/ray")
        )
    }

    @Test("Nothing that is not a pull request parses as one")
    func rejectsNonsense() {
        #expect(WorkspaceCheckoutPlan.parseReference("") == nil)
        #expect(WorkspaceCheckoutPlan.parseReference("main") == nil)
        #expect(WorkspaceCheckoutPlan.parseReference("0") == nil)
        #expect(WorkspaceCheckoutPlan.parseReference("-3") == nil)
        #expect(WorkspaceCheckoutPlan.parseReference("https://github.com/spatie/ray/issues/7") == nil)
    }

    @Test("A pull request pasted from another repository is refused rather than resolved")
    func refusesAnotherRepository() {
        let problem = WorkspaceCheckoutResolver.problem(
            with: "https://github.com/spatie/ray/pull/7", in: "spatie/laravel-backup"
        )
        #expect(problem?.contains("spatie/ray") == true)
        #expect(
            WorkspaceCheckoutResolver.problem(
                with: "https://github.com/Spatie/Ray/pull/7", in: "spatie/ray"
            ) == nil
        )
        #expect(WorkspaceCheckoutResolver.problem(with: "7", in: "spatie/ray") == nil)
        #expect(WorkspaceCheckoutResolver.problem(with: "  ", in: nil) != nil)
    }

    // MARK: - Names

    @Test("A pull request from this repository keeps its own branch name")
    func keepsHeadBranchName() {
        let checkout = WorkspaceCheckout.pullRequest(listing(head: "fix-parser"))
        #expect(checkout.preferredLocalBranch == "fix-parser")
        #expect(WorkspaceCheckoutPlan.localBranch(for: checkout, taken: []) == "fix-parser")
    }

    @Test("A fork's pull request keeps its head name, which is what gh looks it up by")
    func keepsForkHeadName() {
        let checkout = WorkspaceCheckout.pullRequest(
            listing(head: "patch-1", fork: true, owner: "someone")
        )
        #expect(checkout.preferredLocalBranch == "patch-1")
        #expect(WorkspaceCheckoutPlan.localBranch(for: checkout, taken: []) == "patch-1")
    }

    @Test("A fork's head name that is taken falls back to the owner's prefix")
    func prefixesForkBranchesOnCollision() {
        let checkout = WorkspaceCheckout.pullRequest(
            listing(head: "patch-1", fork: true, owner: "someone")
        )
        #expect(
            WorkspaceCheckoutPlan.localBranch(for: checkout, taken: ["patch-1"]) == "someone-patch-1"
        )
        let twice = WorkspaceCheckoutPlan.localBranch(
            for: checkout, taken: ["patch-1", "someone-patch-1"]
        )
        #expect(twice.hasPrefix("someone-patch-1"))
        #expect(twice != "someone-patch-1")
    }

    /// **Changed deliberately, and this test is where the old rule lived.** It used to take a
    /// suffix here, on the argument that a local branch of that name might be a stale head. But
    /// `taken` is every branch in the project, so a pull request raised from this repository
    /// always collides with its own head the moment it has been fetched, which for your own work
    /// is always. The result was that "Open, and carry on" on your own pull request opened
    /// `<head>-2`, a branch with no pull request on it: the strip offered Create pull request for
    /// one that was already open, and push and merge never appeared. Reported from a real
    /// workspace made off a real pull request.
    ///
    /// `gh pr checkout` brings an existing branch up to the head, so the staleness the suffix was
    /// guarding against is answered by the checkout rather than by the name.
    @Test("Your own pull request opens the branch it is about, even when it is already local")
    func opensItsOwnHeadBranch() {
        let checkout = WorkspaceCheckout.pullRequest(listing(head: "fix-parser"))
        #expect(
            WorkspaceCheckoutPlan.localBranch(for: checkout, taken: ["main", "fix-parser"])
                == "fix-parser"
        )
        // And with no local copy yet, which was always the easy case.
        #expect(
            WorkspaceCheckoutPlan.localBranch(for: checkout, taken: ["main"]) == "fix-parser"
        )
    }

    @Test("An existing local branch is opened as it is, not copied under a new name")
    func opensExistingBranchInPlace() {
        let checkout = WorkspaceCheckout.branch(ExistingBranch(name: "wip", isLocal: true))
        #expect(WorkspaceCheckoutPlan.localBranch(for: checkout, taken: ["main", "wip"]) == "wip")
    }

    @Test("A branch checked out from the remote keeps its own name on the row")
    func keepsRemoteBranchNameOnTheRow() {
        // The picker's `isLocal` is a measurement, not an instruction: a branch listed as remote
        // whose local copy already exists must still land on that name, or the row names a branch
        // the worktree is not on.
        let checkout = WorkspaceCheckout.branch(ExistingBranch(name: "wip", isLocal: false))
        #expect(WorkspaceCheckoutPlan.localBranch(for: checkout, taken: ["main", "wip"]) == "wip")
    }

    @Test("The workspace is named after the pull request, number first")
    func namesAfterThePullRequest() {
        #expect(
            WorkspaceCheckout.pullRequest(listing(number: 12, title: "Fix the parser")).workspaceName
                == "#12 Fix the parser"
        )
        #expect(
            WorkspaceCheckout.branch(ExistingBranch(name: "wip", isLocal: true)).workspaceName == "wip"
        )
    }

    // MARK: - What the diff is measured against

    @Test("A pull request is diffed against its own base, not the project's default branch")
    func diffsAgainstThePullRequestsBase() {
        let checkout = WorkspaceCheckout.pullRequest(listing(base: "v3"))
        #expect(checkout.baseBranch(default: "main") == "v3")
    }

    @Test("A branch has nobody to ask, so it falls back to the default branch")
    func branchFallsBackToTheDefault() {
        let checkout = WorkspaceCheckout.branch(ExistingBranch(name: "wip", isLocal: true))
        #expect(checkout.baseBranch(default: "main") == "main")
    }

    // MARK: - Collisions and states

    @Test("A live workspace on that branch is found; an archived one is not")
    func findsTheWorkspaceHoldingABranch() {
        let repoID = RepoID("r")
        var archived = Workspace(
            repoID: repoID, name: "old", branch: "fix-parser", path: "/tmp/a", baseBranch: "main"
        )
        archived.state = .archived
        let live = Workspace(
            repoID: repoID, name: "review", branch: "fix-parser", path: "/tmp/b", baseBranch: "main"
        )
        #expect(
            WorkspaceCheckoutPlan.workspaceHolding(
                branch: "fix-parser", in: repoID, among: [archived, live]
            )?.name == "review"
        )
        #expect(
            WorkspaceCheckoutPlan.workspaceHolding(
                branch: "fix-parser", in: repoID, among: [archived]
            ) == nil
        )
    }

    /// Git's refusal to check a branch out twice is **per repository**, and a branch name is not
    /// unique across them: `main`, `develop` and `staging` exist in nearly every project on a
    /// machine. Matching on the name alone meant the create sheet for one project labelled its own
    /// `develop` as held by a workspace in another, and picking that row dismissed the sheet and
    /// selected the other project's workspace.
    @Test("a branch of the same name in another project is not this project's branch")
    func doesNotReachIntoAnotherProject() {
        let mine = RepoID("bloom")
        let theirs = RepoID("beacon")
        let elsewhere = Workspace(
            repoID: theirs, name: "Beacon develop", branch: "develop",
            path: "/tmp/beacon", baseBranch: "main"
        )
        let here = Workspace(
            repoID: mine, name: "Bloom develop", branch: "develop",
            path: "/tmp/bloom", baseBranch: "main"
        )

        #expect(
            WorkspaceCheckoutPlan.workspaceHolding(
                branch: "develop", in: mine, among: [elsewhere]
            ) == nil
        )
        #expect(
            WorkspaceCheckoutPlan.workspaceHolding(
                branch: "develop", in: mine, among: [elsewhere, here]
            )?.name == "Bloom develop"
        )
        #expect(
            WorkspaceCheckoutPlan.workspaceHolding(
                branch: "develop", in: theirs, among: [elsewhere, here]
            )?.name == "Beacon develop"
        )
    }

    @Test("A merged or closed pull request opens, and says so first")
    func warnsAboutDeadPullRequests() {
        #expect(
            WorkspaceCheckoutPlan.warning(for: .pullRequest(listing(state: "MERGED")))?
                .contains("merged") == true
        )
        #expect(
            WorkspaceCheckoutPlan.warning(for: .pullRequest(listing(state: "CLOSED")))?
                .contains("closed") == true
        )
        #expect(WorkspaceCheckoutPlan.warning(for: .pullRequest(listing())) == nil)
        #expect(
            WorkspaceCheckoutPlan.warning(for: .branch(ExistingBranch(name: "wip", isLocal: true)))
                == nil
        )
    }

    // MARK: - gh's shape

    @Test("gh's list JSON decodes, logins and all")
    func decodesGHOutput() throws {
        let json = """
        [
          {
            "number": 41,
            "title": "Add a thing",
            "author": {"login": "contributor"},
            "headRefName": "add-a-thing",
            "baseRefName": "main",
            "isDraft": false,
            "state": "OPEN",
            "isCrossRepository": true,
            "headRepositoryOwner": {"login": "contributor"}
          }
        ]
        """
        let decoded = try GitHub.decodePullRequestListings(from: Data(json.utf8))
        #expect(decoded.count == 1)
        #expect(decoded[0].number == 41)
        #expect(decoded[0].author == "contributor")
        #expect(decoded[0].headRepositoryOwner == "contributor")
        #expect(decoded[0].isCrossRepository)
        #expect(WorkspaceCheckout.pullRequest(decoded[0]).preferredLocalBranch == "add-a-thing")
        #expect(
            WorkspaceCheckout.pullRequest(decoded[0]).alternateLocalBranch == "contributor-add-a-thing"
        )
    }

    @Test("A gh version that omits a field decodes rather than throwing")
    func decodesSparseOutput() throws {
        let decoded = try GitHub.decodePullRequestListings(
            from: Data("""
            [{"number": 3, "title": "t", "headRefName": "h", "baseRefName": "b"}]
            """.utf8)
        )
        #expect(decoded[0].state == "OPEN")
        #expect(decoded[0].author.isEmpty)
        #expect(!decoded[0].isCrossRepository)
    }

    @Test("A repository that is not on GitHub is recognised from gh's own words")
    func recognisesNoGitHubRemote() {
        #expect(
            GitHub.indicatesNotAGitHubRepository(
                stderr: "none of the git remotes configured for this repository point to a known GitHub host"
            )
        )
        #expect(!GitHub.indicatesNotAGitHubRepository(stderr: "could not connect to github.com"))
    }
}
