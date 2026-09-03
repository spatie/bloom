import Testing
import Foundation
@testable import BloomCore

@Suite("Branch rename gate", .tags(.destructive))
struct BranchRenameGateTests {
    /// A workspace as it stands a few seconds after being created: on the branch Bloom cut, no
    /// commits, nothing pushed.
    private func facts(
        desired: String = "dark-mode-toggle",
        commitsAhead: Int = 0,
        hasUpstream: Bool = false,
        hasRemoteCounterpart: Bool = false,
        hasPullRequest: Bool = false,
        hasOperationInProgress: Bool = false,
        checkedOut: String? = "add-a-toggle-to-settings",
        taken: Set<String> = ["main", "add-a-toggle-to-settings"]
    ) -> BranchRenameFacts {
        BranchRenameFacts(
            recordedBranch: "add-a-toggle-to-settings",
            checkedOutBranch: checkedOut,
            desiredBranch: desired,
            commitsAhead: commitsAhead,
            hasUpstream: hasUpstream,
            hasRemoteCounterpart: hasRemoteCounterpart,
            hasPullRequest: hasPullRequest,
            hasOperationInProgress: hasOperationInProgress,
            takenBranches: taken
        )
    }

    @Test("a branch nothing depends on is renamed")
    func allowed() {
        #expect(BranchRenameGate.decide(facts()) == .rename(to: "dark-mode-toggle"))
    }

    @Test("a commit on the branch stops it")
    func commits() {
        #expect(BranchRenameGate.decide(facts(commitsAhead: 1)).refusal == .hasCommits(1))
    }

    @Test("an upstream stops it, because the pushed branch would be left behind")
    func upstream() {
        #expect(BranchRenameGate.decide(facts(hasUpstream: true)).refusal == .pushed)
    }

    @Test("a push without an upstream stops it too")
    func pushedWithoutUpstream() {
        // `git push origin HEAD` sets no upstream but still leaves a branch on the remote, and a
        // check that only looked at the upstream would rename straight past it.
        #expect(BranchRenameGate.decide(facts(hasRemoteCounterpart: true)).refusal == .pushed)
    }

    @Test("a pull request stops it, and is the reason reported")
    func pullRequest() {
        let decision = BranchRenameGate.decide(
            facts(commitsAhead: 3, hasUpstream: true, hasPullRequest: true)
        )
        #expect(decision.refusal == .hasPullRequest)
    }

    @Test("a branch the user renamed by hand is left alone")
    func renamedByHand() {
        let decision = BranchRenameGate.decide(facts(checkedOut: "my-own-branch"))
        #expect(decision.refusal == .renamedByHand("my-own-branch"))
    }

    @Test("a detached HEAD is not a branch to rename")
    func detached() {
        #expect(BranchRenameGate.decide(facts(checkedOut: nil)).refusal == .detachedHead)
    }

    @Test("a half finished rebase stops it")
    func operationInProgress() {
        #expect(
            BranchRenameGate.decide(facts(hasOperationInProgress: true)).refusal
                == .operationInProgress
        )
    }

    @Test("a name another branch already has is refused rather than suffixed")
    func nameTaken() {
        let decision = BranchRenameGate.decide(
            facts(desired: "dark-mode", taken: ["main", "add-a-toggle-to-settings", "dark-mode"])
        )
        #expect(decision.refusal == .nameTaken("dark-mode"))
    }

    @Test("a branch that already has the name it would be given is left as it is")
    func alreadyNamed() {
        #expect(
            BranchRenameGate.decide(facts(desired: "add-a-toggle-to-settings")).refusal
                == .alreadyNamed
        )
    }

    @Test(
        "nothing git would read as an option or refuse outright reaches `git branch -m`",
        .tags(.security),
        arguments: ["", "   ", "--mirror", "-f", "HEAD", "..", "a//b", "a b", "with\nnewline"]
    )
    func refusesUnsafeNames(desired: String) {
        #expect(BranchRenameGate.decide(facts(desired: desired)).refusal == .noValidName)
    }

    @Test("the two refusals that changed nothing visible are the two that stay quiet")
    func reportability() {
        #expect(!BranchRenameRefusal.alreadyNamed.isWorthReporting)
        #expect(!BranchRenameRefusal.noValidName.isWorthReporting)
        for refusal: BranchRenameRefusal in [
            .hasCommits(1), .pushed, .hasPullRequest, .renamedByHand("x"),
            .detachedHead, .operationInProgress, .nameTaken("x"), .gitRefused("no"),
        ] {
            #expect(refusal.isWorthReporting)
            #expect(!refusal.reason.isEmpty)
        }
    }

    @Test("one commit reads as one commit")
    func pluralisation() {
        #expect(BranchRenameRefusal.hasCommits(1).reason.contains("1 commit on it"))
        #expect(BranchRenameRefusal.hasCommits(4).reason.contains("4 commits on it"))
    }
}

@Suite("Renaming a branch for real", .tags(.git, .destructive), .scratchDirectory)
struct BranchRenameGitTests {
    @Test("a branch checked out in a worktree can be renamed under it")
    func renamesUnderWorktree() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        let store = try makeTestStore("rename")
        let manager = WorkspaceManager(store: store)
        let registered = try await manager.addRepository(at: repo.path)

        let workspace = try await manager.createWorkspace(
            repo: registered, prompt: "Add a toggle to the settings screen"
        )
        let file = (workspace.path as NSString).appendingPathComponent("README.md")
        #expect(FileManager.default.fileExists(atPath: file))

        try await Git.renameBranch(workspace.branch, to: "dark-mode-toggle", in: workspace.path)

        #expect(try await Git.currentBranch(of: workspace.path) == "dark-mode-toggle")
        // The checkout is untouched: a rename moves a ref, not files.
        #expect(FileManager.default.fileExists(atPath: file))
        #expect(await Git.branchExists("dark-mode-toggle", in: repo.path))
        #expect(!(await Git.branchExists(workspace.branch, in: repo.path)))
    }

    @Test("the facts a rename is decided on are read out of the repository", .tags(.subprocess))
    func gathersFacts() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        let manager = WorkspaceManager(store: try makeTestStore("facts"))
        let registered = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(
            repo: registered, prompt: "Add a toggle to the settings screen"
        )

        var facts = try await manager.branchRenameFacts(
            workspace: workspace, desiredBranch: "dark-mode", hasPullRequest: false
        )
        #expect(facts.checkedOutBranch == workspace.branch)
        #expect(facts.commitsAhead == 0)
        #expect(!facts.hasUpstream)
        #expect(!facts.hasRemoteCounterpart)
        #expect(!facts.hasOperationInProgress)
        #expect(facts.takenBranches.contains("main"))
        #expect(BranchRenameGate.decide(facts) == .rename(to: "dark-mode"))

        // One commit from the agent, and the same question answers differently.
        let worktree = TempRepo(existing: workspace.path)
        try worktree.write("toggle.swift", "// work\n")
        try await worktree.commit("start the toggle")

        facts = try await manager.branchRenameFacts(
            workspace: workspace, desiredBranch: "dark-mode", hasPullRequest: false
        )
        #expect(facts.commitsAhead == 1)
        #expect(BranchRenameGate.decide(facts).refusal == .hasCommits(1))
    }

    /// The cautious fallback the facts-gathering comment promises, actually firing.
    ///
    /// A base branch that no longer resolves is the likeliest way the commit count fails, and it
    /// used to come back as a clean 0 because the git call swallowed the non-zero exit. Nought
    /// commits is what an untouched branch looks like, so a workspace whose base had been deleted
    /// was renamed on the strength of an answer nobody had. One commit is the honest stand-in for
    /// "git would not say", and it refuses.
    @Test("a base branch git cannot resolve refuses the rename rather than allowing it", .tags(.subprocess))
    func refusesWhenTheCountCannotBeRead() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        let manager = WorkspaceManager(store: try makeTestStore("unreadable-count"))
        let registered = try await manager.addRepository(at: repo.path)
        var workspace = try await manager.createWorkspace(
            repo: registered, prompt: "Add a toggle to the settings screen"
        )
        workspace.baseBranch = "a-branch-that-is-not-here"

        let facts = try await manager.branchRenameFacts(
            workspace: workspace, desiredBranch: "dark-mode", hasPullRequest: false
        )

        #expect(facts.commitsAhead == 1)
        #expect(BranchRenameGate.decide(facts).refusal == .hasCommits(1))
    }

    @Test("a half finished merge is seen", .tags(.subprocess))
    func seesOperationInProgress() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }

        #expect(!(await Git.hasOperationInProgress(in: repo.path)))

        // A MERGE_HEAD in the git directory is what an interrupted merge leaves behind.
        let head = try await Git.headSHA(of: repo.path)
        let marker = (repo.path as NSString).appendingPathComponent(".git/MERGE_HEAD")
        try (head + "\n").write(toFile: marker, atomically: true, encoding: .utf8)

        #expect(await Git.hasOperationInProgress(in: repo.path))
    }

    @Test("a branch pushed to a remote is found without a network", .tags(.subprocess))
    func seesRemoteCounterpart() async throws {
        let origin = try await TempRepo()
        defer { origin.cleanUp() }
        let clone = TestScratch.unique("bloom-clone")
        try await Shell.check("git", ["clone", "-q", origin.path, clone])
        defer { try? FileManager.default.removeItem(atPath: clone) }

        #expect(!(await Git.hasRemoteCounterpart("nothing-pushed", in: clone)))
        // `main` came down with the clone, so a remote-tracking ref for it exists.
        let branch = try await Git.currentBranch(of: clone) ?? "main"
        #expect(await Git.hasRemoteCounterpart(branch, in: clone))
    }
}
