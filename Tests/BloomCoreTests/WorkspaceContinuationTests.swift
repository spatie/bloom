import Testing
import Foundation
@testable import BloomCore

@Suite("Continuation gate", .tags(.destructive))
struct ContinuationGateTests {
    /// A workspace as it stands the moment its pull request goes in: still on the branch Bloom
    /// cut, nothing else happening to it.
    private func facts(
        mergedBranch: String = "dark-mode-toggle",
        checkedOut: String? = "dark-mode-toggle",
        base: String = "main",
        merged: Bool = true,
        agentRunning: Bool = false,
        operationInProgress: Bool = false,
        taken: Set<String> = ["main", "dark-mode-toggle"]
    ) -> ContinuationFacts {
        ContinuationFacts(
            mergedBranch: mergedBranch,
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

    @Test("a branch switched by hand stops it, and both branches are named in the refusal")
    func switchedByHand() {
        let decision = ContinuationGate.decide(facts(checkedOut: "something-else"))
        #expect(
            decision.refusal
                == .switchedByHand(
                    onBranch: "something-else", pullRequestBranch: "dark-mode-toggle"
                )
        )
        let sentence = decision.refusal?.sentence ?? ""
        #expect(sentence.contains("something-else"))
        #expect(sentence.contains("dark-mode-toggle"))
    }

    @Test("the branch an agent cut for itself is continued from, not refused")
    func agentCutItsOwnBranch() {
        // The report this whole comparison was rewritten for. The row said one thing, the reflog
        // showed the agent cutting its own branch off it fourteen minutes in, and pull request
        // #381 merged the branch the worktree was actually on. The strip found that pull request,
        // because it asks about the live branch, and Continue then refused with a sentence naming
        // the very branch the pull request was for.
        let decision = ContinuationGate.decide(
            facts(
                mergedBranch: "freekmurze/fix-stuck-channel-deletions",
                checkedOut: "freekmurze/fix-stuck-channel-deletions",
                taken: [
                    "main",
                    "freekmurze/seto-inland-sea",
                    "freekmurze/investigate-problem",
                    "freekmurze/fix-stuck-channel-deletions",
                ]
            )
        )
        // And the new branch counts on from the branch that merged rather than from the name the
        // work stopped using two hours earlier.
        #expect(decision == .cut(branch: "freekmurze/fix-stuck-channel-deletions-2"))
    }

    @Test("a worktree parked on the base branch has nothing to continue from")
    func onBase() {
        let decision = ContinuationGate.decide(facts(mergedBranch: "main", checkedOut: "main"))
        #expect(decision.refusal == .onBaseBranch("main"))

        // And it stays that sentence when the pull request was for a branch of its own, which is
        // the ordinary shape of it: parked on main is not the same complaint as moved elsewhere,
        // and it is checked first so the more specific one wins.
        let parked = ContinuationGate.decide(
            facts(mergedBranch: "dark-mode-toggle", checkedOut: "main")
        )
        #expect(parked.refusal == .onBaseBranch("main"))
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
            .notMerged, .agentRunning, .detachedHead,
            .switchedByHand(onBranch: "other", pullRequestBranch: "dark-mode-toggle"),
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

    /// The pull request the strip would be showing, for whichever branch is named. gh reports the
    /// head branch and `PullRequest.branch` is where it lands, which is what the gate weighs the
    /// checkout against.
    private func merged(_ branch: String, number: Int = 370) -> PullRequest {
        PullRequest(
            number: number,
            title: "Add the toggle",
            url: "https://github.com/example/repo/pull/\(number)",
            state: "MERGED",
            branch: branch,
            closedAt: Date()
        )
    }

    @Test("the worktree stays put, moves to a new branch, and the merged one is left alone")
    func continuesInPlace() async throws {
        let (origin, repo, _, manager, workspace) = try await makeMergedWorkspace()
        defer { repo.cleanUp(); origin.cleanUp() }

        let facts = try await manager.continuationFacts(
            workspace: workspace,
            pullRequest: merged(workspace.branch),
            isAgentRunning: false
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
            workspace: workspace,
            pullRequest: merged(workspace.branch),
            isAgentRunning: false
        )

        #expect(facts.mergedBranch == workspace.branch)
        #expect(facts.isPullRequestMerged)
        #expect(facts.checkedOutBranch == workspace.branch)
        #expect(facts.baseBranch == workspace.baseBranch)
        #expect(facts.hasOperationInProgress == false)
        #expect(facts.takenBranches.contains(workspace.branch))
        #expect(facts.takenBranches.contains("main"))
    }

    @Test("the branch an agent cut for itself is the one continued from, row or no row")
    func continuesFromTheAgentsOwnBranch() async throws {
        let (origin, repo, _, manager, workspace) = try await makeMergedWorkspace()
        defer { repo.cleanUp(); origin.cleanUp() }

        // What the reported workspace's reflog shows: fourteen minutes in, the agent cut a better
        // named branch off the one Bloom made and did the work there. Nothing writes that back to
        // the row, and nothing is supposed to.
        try await Shell.check(
            "git", ["checkout", "-q", "-b", "fix-stuck-channel-deletions"], cwd: workspace.path
        )
        let worktree = TempRepo(existing: workspace.path)
        try worktree.write("fix.swift", "let fixed = true\n")
        try await worktree.commit("Fix the thing")
        try await Shell.check(
            "git", ["push", "-q", "origin", "HEAD:refs/heads/main"], cwd: workspace.path
        )

        let facts = try await manager.continuationFacts(
            workspace: workspace,
            pullRequest: merged("fix-stuck-channel-deletions", number: 381),
            isAgentRunning: false
        )
        #expect(facts.mergedBranch == "fix-stuck-channel-deletions")
        #expect(facts.checkedOutBranch == "fix-stuck-channel-deletions")
        // The row is still where it was, which is the exact state that used to be refused.
        #expect(workspace.branch != "fix-stuck-channel-deletions")

        let branch = try #require(ContinuationGate.decide(facts).branch)
        #expect(branch == "fix-stuck-channel-deletions-2")

        let continuation = try await manager.continueOnNewBranch(
            workspace: workspace, branch: branch
        )

        // The branch left behind is the one the work was on, not the one the row remembered, and
        // it is the name the agent's own prompt is about to be rendered with.
        #expect(continuation.previousBranch == "fix-stuck-channel-deletions")
        #expect(continuation.workspace.branch == branch)
        #expect(try await Git.currentBranch(of: workspace.path) == branch)

        // And the row has caught up, so the next reader of it is not two branches behind.
        let stored = try await manager.store.workspace(id: workspace.id)
        #expect(stored?.branch == branch)
    }
}

@Suite("What the continue prompt says")
struct ContinuationPromptTests {
    private var continuation: WorkspaceContinuation {
        WorkspaceContinuation(
            workspace: Workspace(
                repoID: RepoID("repo"),
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

@Suite("Which branch the merged pull request is for")
struct ContinuationHeadTests {
    private func pullRequest(branch: String) -> PullRequest {
        PullRequest(
            number: 381,
            title: "Finish channel deletions that time out",
            url: "https://github.com/example/repo/pull/381",
            state: "MERGED",
            branch: branch
        )
    }

    @Test("gh's own head branch is the answer whenever there is one")
    func reported() {
        #expect(
            ContinuationHead.branch(
                of: pullRequest(branch: "fix-stuck-channel-deletions"),
                recorded: "investigate-problem",
                checkedOut: "fix-stuck-channel-deletions",
                base: "main"
            ) == "fix-stuck-channel-deletions"
        )
    }

    @Test("without one it falls back to the branch the pull request was looked up under")
    func fallsBackToTheLiveBranch() {
        // A gh too old to report a head branch still found this pull request, and it found it by
        // asking about the branch the worktree is on now. That rule is `PullRequestHead`, and
        // this asks it rather than keeping a second copy that can disagree with the strip.
        #expect(
            ContinuationHead.branch(
                of: pullRequest(branch: ""),
                recorded: "investigate-problem",
                checkedOut: "fix-stuck-channel-deletions",
                base: "main"
            ) == "fix-stuck-channel-deletions"
        )
    }

    @Test("a worktree standing on the base falls back to the row, which the gate then refuses")
    func onTheBase() {
        #expect(
            ContinuationHead.branch(
                of: pullRequest(branch: ""),
                recorded: "dark-mode",
                checkedOut: "main",
                base: "main"
            ) == "dark-mode"
        )
    }

    @Test("whitespace out of gh is not a head branch")
    func blank() {
        #expect(
            ContinuationHead.branch(
                of: pullRequest(branch: "   "),
                recorded: "dark-mode",
                checkedOut: "dark-mode",
                base: "main"
            ) == "dark-mode"
        )
    }
}

@Suite("What the strip says once a workspace has continued")
struct ContinuedBranchTests {
    private let continued = ContinuedBranch(
        branch: "dark-mode-toggle-2",
        previousBranch: "dark-mode-toggle",
        baseBranch: "main",
        pullRequest: 381
    )

    @Test("a workspace that has never continued keeps the ordinary line")
    func ordinary() {
        #expect(
            ContinuedBranch.line(on: "dark-mode-toggle", continued: nil)
                == "Nothing has changed on this branch yet."
        )
    }

    @Test("a branch cut from a merge says where it came from and why it is empty")
    func afterContinuing() {
        let line = ContinuedBranch.line(on: "dark-mode-toggle-2", continued: continued)
        #expect(line.contains("main"))
        #expect(line.contains("#381"))
        #expect(line.contains("Nothing on it yet"))
        #expect(line != "Nothing has changed on this branch yet.")
    }

    @Test("it stops describing the workspace the moment the worktree is somewhere else")
    func onlyForTheBranchItNames() {
        // Held in memory and never cleared, which is only safe because of this: an agent that
        // cuts its own branch two minutes later must not be described as the branch Continue made.
        #expect(
            ContinuedBranch.line(on: "something-the-agent-cut", continued: continued)
                == "Nothing has changed on this branch yet."
        )
    }

    @Test("with no pull request number it names the branch that merged instead")
    func withoutANumber() {
        var unnumbered = continued
        unnumbered.pullRequest = 0
        let line = ContinuedBranch.line(on: "dark-mode-toggle-2", continued: unnumbered)
        #expect(line.contains("dark-mode-toggle"))
        #expect(line.contains("#") == false)
    }

    @Test("it is built from the continuation the app is already holding")
    func fromTheContinuation() {
        let continuation = WorkspaceContinuation(
            workspace: Workspace(
                repoID: RepoID("repo"),
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
        #expect(ContinuedBranch(continuation, pullRequest: 381) == continued)
    }
}
