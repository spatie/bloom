import Testing
import Foundation
@testable import BloomCore

@Suite("Continuation gate", .tags(.destructive))
struct ContinuationGateTests {
    /// A workspace as it stands the moment its pull request goes in: still on the branch Bloom
    /// cut, nothing else happening to it.
    private func facts(
        recorded: String = "dark-mode-toggle",
        checkedOut: String? = "dark-mode-toggle",
        base: String = "main",
        merged: Bool = true,
        agentRunning: Bool = false,
        operationInProgress: Bool = false,
        taken: Set<String> = ["main", "dark-mode-toggle"]
    ) -> ContinuationFacts {
        ContinuationFacts(
            recordedBranch: recorded,
            checkedOutBranch: checkedOut,
            baseBranch: base,
            isPullRequestMerged: merged,
            isAgentRunning: agentRunning,
            hasOperationInProgress: operationInProgress,
            takenBranches: taken
        )
    }

    @Test("a merged workspace sitting still is continued on the next branch along")
    func allowed() {
        #expect(ContinuationGate.decide(facts()) == .cut(branch: "dark-mode-toggle-2"))
    }

    @Test("a pull request that has not landed is the whole justification, so it is checked first")
    func notMerged() {
        // Everything else about this workspace is fine. Without the merge there is nothing on the
        // base branch to cut from and the branch is still live work.
        #expect(ContinuationGate.decide(facts(merged: false)).refusal == .notMerged)
    }

    @Test("a running agent stops it, above everything else that is wrong")
    func agentRunning() {
        let decision = ContinuationGate.decide(
            facts(agentRunning: true, operationInProgress: true)
        )
        #expect(decision.refusal == .agentRunning)
    }

    @Test("a detached HEAD stops it, because its commits are held by nothing else")
    func detached() {
        #expect(ContinuationGate.decide(facts(checkedOut: nil)).refusal == .detachedHead)
    }

    @Test("a branch switched by hand stops it, and is named in the refusal")
    func switchedByHand() {
        let decision = ContinuationGate.decide(facts(checkedOut: "something-else"))
        #expect(decision.refusal == .switchedByHand("something-else"))
    }

    @Test("a worktree parked on the base branch has nothing to continue from")
    func onBase() {
        let decision = ContinuationGate.decide(facts(recorded: "main", checkedOut: "main"))
        #expect(decision.refusal == .onBaseBranch("main"))
    }

    @Test("a half finished rebase stops it")
    func operationInProgress() {
        #expect(
            ContinuationGate.decide(facts(operationInProgress: true)).refusal
                == .operationInProgress
        )
    }

    @Test("every refusal says something")
    func everyRefusalHasASentence() {
        let refusals: [ContinuationRefusal] = [
            .notMerged, .agentRunning, .detachedHead, .switchedByHand("other"),
            .operationInProgress, .onBaseBranch("main"), .noValidName,
        ]
        for refusal in refusals {
            #expect(!refusal.sentence.isEmpty)
            #expect(refusal.sentence.hasSuffix("."))
        }
    }
}

@Suite("Continuation branch naming")
struct ContinuationBranchTests {
    @Test("the first continuation is the branch with -2 on it")
    func first() {
        #expect(
            ContinuationBranch.next(after: "dark-mode", taken: ["main", "dark-mode"])
                == "dark-mode-2"
        )
    }

    @Test("continuing a continuation counts on rather than nesting")
    func second() {
        // Not `dark-mode-2-2`. The stem is stripped because `dark-mode` is a branch that really
        // exists, which is what makes the trailing number a counter rather than part of the name.
        #expect(
            ContinuationBranch.next(after: "dark-mode-2", taken: ["main", "dark-mode", "dark-mode-2"])
                == "dark-mode-3"
        )
    }

    @Test("a number that is part of the name is not read as a counter")
    func numberInName() {
        // `fix-utf` is not a branch, so `-8` belongs to the name and the answer keeps it.
        #expect(
            ContinuationBranch.next(after: "fix-utf-8", taken: ["main", "fix-utf-8"])
                == "fix-utf-8-2"
        )
    }

    @Test("a configured prefix comes along untouched")
    func prefix() {
        #expect(
            ContinuationBranch.next(after: "freek/dark-mode", taken: ["main", "freek/dark-mode"])
                == "freek/dark-mode-2"
        )
    }

    @Test("it counts past names that are already taken")
    func skipsTaken() {
        let taken: Set<String> = ["main", "dark-mode", "dark-mode-2", "dark-mode-3"]
        #expect(ContinuationBranch.next(after: "dark-mode", taken: taken) == "dark-mode-4")
    }

    @Test("a branch that is only a number is left alone")
    func onlyDigits() {
        // Stripping would leave an empty stem, which is not a branch name at all.
        #expect(ContinuationBranch.stem(of: "2", taken: ["2"]) == "2")
        #expect(ContinuationBranch.stem(of: "-2", taken: ["-2"]) == "-2")
    }
}

@Suite("Continuing a merged workspace", .tags(.git, .destructive), .scratchDirectory)
struct WorkspaceContinuationTests {
    /// A repository with a remote, a workspace cut from it, and one commit on the branch that has
    /// already been merged into the remote's `main`. The shape Continue exists for.
    private func makeMergedWorkspace() async throws -> (
        origin: TempRepo, repo: TempRepo, registered: Repo,
        manager: WorkspaceManager, workspace: Workspace
    ) {
        let origin = try await TempRepo()
        // Nothing here ever reads the origin's own checkout, and git refuses by default to update
        // the branch a non-bare repository has checked out. This is the one line that makes a
        // plain directory usable as a stand-in for GitHub.
        try await Shell.check(
            "git", ["config", "receive.denyCurrentBranch", "ignore"], cwd: origin.path
        )
        let clonePath = TestScratch.unique("bloom-clone")
        try await Shell.check("git", ["clone", "-q", "--", origin.path, clonePath], cwd: origin.path)
        let repo = TempRepo(existing: clonePath)
        try await Shell.check("git", ["config", "user.email", "test@bloom.local"], cwd: repo.path)
        try await Shell.check("git", ["config", "user.name", "Bloom Test"], cwd: repo.path)
        try await Shell.check("git", ["config", "commit.gpgsign", "false"], cwd: repo.path)

        let manager = WorkspaceManager(store: try makeTestStore("continue"))
        let registered = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(
            repo: registered, prompt: "Add a dark mode toggle"
        )

        // The branch does its work and lands on the remote's main, which is what a merged pull
        // request leaves behind.
        let worktree = TempRepo(existing: workspace.path)
        try worktree.write("toggle.swift", "let dark = true\n")
        try await worktree.commit("Add the toggle")
        try await Shell.check(
            "git", ["push", "-q", "origin", "HEAD:refs/heads/main"], cwd: workspace.path
        )

        return (origin, repo, registered, manager, workspace)
    }

    @Test("the worktree stays put, moves to a new branch, and the merged one is left alone")
    func continuesInPlace() async throws {
        let (origin, repo, _, manager, workspace) = try await makeMergedWorkspace()
        defer { repo.cleanUp(); origin.cleanUp() }

        let facts = try await manager.continuationFacts(
            workspace: workspace, isPullRequestMerged: true, isAgentRunning: false
        )
        let branch = try #require(ContinuationGate.decide(facts).branch)

        let continuation = try await manager.continueOnNewBranch(
            workspace: workspace, branch: branch
        )

        // Same directory. That is the whole point: the session, the setup and the dev servers all
        // live at this path.
        #expect(continuation.workspace.path == workspace.path)
        #expect(continuation.branch == branch)
        #expect(continuation.previousBranch == workspace.branch)
        #expect(continuation.workspace.branch == branch)
        #expect(try await Git.currentBranch(of: workspace.path) == branch)

        // Cut from the remote's main, which is where the work landed, so the toggle is underneath.
        #expect(continuation.base == .fetched)
        #expect(TempRepo(existing: workspace.path).read("toggle.swift") != nil)

        // The merged branch is still here, holding its commits. Nothing was renamed or deleted.
        let branches = Set(try await Git.branches(of: repo.path))
        #expect(branches.contains(workspace.branch))
        #expect(branches.contains(branch))

        // And the store agrees with the repository.
        let stored = try await manager.store.workspace(id: workspace.id)
        #expect(stored?.branch == branch)
        #expect(stored?.path == workspace.path)
        #expect(stored?.baseBranch == workspace.baseBranch)
        // The name is not touched. Bloom names a workspace from what was asked for, and nobody has
        // asked for the next thing yet.
        #expect(stored?.name == workspace.name)
    }

    @Test("uncommitted work comes along rather than being stashed or thrown away")
    func carriesUncommittedWork() async throws {
        let (origin, repo, _, manager, workspace) = try await makeMergedWorkspace()
        defer { repo.cleanUp(); origin.cleanUp() }

        let worktree = TempRepo(existing: workspace.path)
        try worktree.write("scratch.md", "half an idea for the next thing\n")
        try worktree.write("README.md", "hello\nedited after the merge\n")

        let continuation = try await manager.continueOnNewBranch(
            workspace: workspace, branch: "dark-mode-next"
        )

        #expect(continuation.carriedUncommittedWork)
        #expect(worktree.read("scratch.md") == "half an idea for the next thing\n")
        #expect(worktree.read("README.md") == "hello\nedited after the merge\n")
    }

    @Test("an unreachable remote falls back to the last fetched base, and says so")
    func fallsBackToTheCachedRemote() async throws {
        let (origin, repo, _, manager, workspace) = try await makeMergedWorkspace()
        defer { repo.cleanUp() }

        // The clone still has refs/remotes/origin/main from the clone itself. Taking the origin
        // away is the offline case: the fetch fails and the cached ref is all there is.
        origin.cleanUp()

        let continuation = try await manager.continueOnNewBranch(
            workspace: workspace, branch: "carry-on"
        )

        #expect(continuation.base == .cachedRemote)
        #expect(continuation.base.warning != nil)
        #expect(try await Git.currentBranch(of: workspace.path) == "carry-on")
    }

    @Test("with no remote to fetch from it falls back to the local base branch")
    func fallsBackWithoutARemote() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }

        let manager = WorkspaceManager(store: try makeTestStore("continue-local"))
        let registered = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(repo: registered, prompt: "Do a thing")

        let continuation = try await manager.continueOnNewBranch(
            workspace: workspace, branch: "do-a-thing-2"
        )

        #expect(continuation.base == .localBranch)
        #expect(continuation.base.warning != nil)
        #expect(try await Git.currentBranch(of: workspace.path) == "do-a-thing-2")
        // The revision really is the local base branch's tip.
        let main = await Git.revision(of: "refs/heads/main", in: repo.path)
        #expect(continuation.revision == main)
    }

    @Test("a base branch that exists nowhere is an error rather than a guess")
    func missingBase() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }

        await #expect(throws: (any Error).self) {
            try await Git.baseRevision(branch: "no-such-branch", in: repo.path)
        }
    }

    @Test("the facts read out of a real worktree are the ones the gate wants")
    func factsFromDisk() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }

        let manager = WorkspaceManager(store: try makeTestStore("continue-facts"))
        let registered = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(repo: registered, prompt: "Do a thing")

        let facts = try await manager.continuationFacts(
            workspace: workspace, isPullRequestMerged: true, isAgentRunning: false
        )

        #expect(facts.recordedBranch == workspace.branch)
        #expect(facts.checkedOutBranch == workspace.branch)
        #expect(facts.baseBranch == workspace.baseBranch)
        #expect(facts.hasOperationInProgress == false)
        #expect(facts.takenBranches.contains(workspace.branch))
        #expect(facts.takenBranches.contains("main"))
    }
}

@Suite("What the continue prompt says")
struct ContinuationPromptTests {
    private var continuation: WorkspaceContinuation {
        WorkspaceContinuation(
            workspace: Workspace(
                repoID: "repo",
                name: "Dark mode toggle",
                branch: "dark-mode-toggle-2",
                path: "/tmp/worktree",
                baseBranch: "main"
            ),
            previousBranch: "dark-mode-toggle",
            branch: "dark-mode-toggle-2",
            revision: "abc123",
            base: .fetched,
            carriedUncommittedWork: false
        )
    }

    @Test("the built-in template resolves against a real continuation")
    func rendersFully() {
        let template = PromptRegistry.definition(for: .continueAfterMerge).defaultTemplate
        let render = continuation.render(template: template, pullRequest: 370)

        #expect(render.unknown.isEmpty)
        #expect(render.missing.isEmpty)
        #expect(render.text.contains("#370"))
        #expect(render.text.contains("dark-mode-toggle-2"))
        #expect(render.text.contains("main"))
    }

    @Test("it tells the agent not to start anything")
    func doesNotBrief() {
        // Continue is a press on a strip, not an instruction. An agent that reads this as a brief
        // will invent one, which is the one way this feature can waste somebody's afternoon.
        let template = PromptRegistry.definition(for: .continueAfterMerge).defaultTemplate
        #expect(template.contains("do not start anything new yet"))
    }

    @Test("the sentence the inspector shows names the branch and the base")
    func sentence() {
        #expect(continuation.sentence.contains("dark-mode-toggle-2"))
        #expect(continuation.sentence.contains("main"))
        #expect(continuation.sentence.contains("uncommitted") == false)
    }

    @Test("carried work is said out loud")
    func carried() {
        var carried = continuation
        carried.carriedUncommittedWork = true
        #expect(carried.sentence.contains("uncommitted"))
    }

    @Test("only a fetched base is silent about where it came from")
    func warnings() {
        #expect(ContinuationBase.fetched.warning == nil)
        #expect(ContinuationBase.cachedRemote.warning != nil)
        #expect(ContinuationBase.localBranch.warning != nil)
    }
}
