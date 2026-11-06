import Foundation
import Testing
@testable import BloomCore

/// Names and values that outlive a launch or leave the app. Renaming one is a migration.
@Suite("GitHub stored values")
struct GitHubStoredValueTests {
    @Test("the keys a pull request's settings and state are stored under")
    func keys() {
        let workspace = WorkspaceID("workspace")
        #expect(PromptOverrides.key(for: .createPullRequest) == "prompts.createPullRequest")
        #expect(MergeMethodChoice.key(repoID: RepoID("repo")) == "repo.repo.mergeMethod")
        #expect(MergeExecutionChoice.key(repoID: RepoID("repo")) == "repo.repo.mergeExecution")
        #expect(ChecksWatch.lastSeenKey(workspaceID: workspace) == "checks.lastSeen.workspace")
        #expect(OnboardingGate.completedKey == "onboarding.completed")
        #expect(NotificationPreferences.key(for: .checksFinished) == "notifications.event.checksFinished")
    }

    @Test("the instruction files a project commits")
    func instructionPaths() {
        #expect(PullRequestInstructions.projectPath == ".bloom/pr-instructions.md")
        #expect(PullRequestInstructions.scratchPath == ".bloom/scratch/pr-instructions.md")
        #expect(ProjectInstructions.projectPath(for: .merge) == ".bloom/merge-instructions.md")
        #expect(ProjectInstructions.projectPath(for: .fixConflicts) == ".bloom/conflict-instructions.md")
        #expect(ConflictInstructions.scratchPath == ".bloom/scratch/resolving-conflicts.md")
    }

    @Test("the values those keys and answers hold")
    func rawValues() {
        #expect(PromptID.allCases.map(\.rawValue) == [
            "createPullRequest", "pushLocalWork", "mergePullRequest", "fixConflicts",
            "continueAfterMerge", "carryOnArchived", "review", "nameWorkspace",
        ])
        #expect(GitHub.MergeMethod.allCases.map(\.rawValue) == ["merge", "squash", "rebase"])
        #expect(MergeExecution.allCases.map(\.rawValue) == ["direct", "agent"])
        #expect(MergeExecution.allCases.map { $0.label(on: .gitHub) } == ["Merge with GitHub CLI", "Ask agent to merge"])
        let checks: [PullRequest.Checks] = [.none, .pending, .passing, .failing, .unavailable]
        #expect(checks.map(\.rawValue) == ["none", "pending", "passing", "failing", "unavailable"])
    }

    @Test("a workspace's status, as a tool answers it and a legend names it")
    func statuses() {
        #expect(WorkspaceStatus.allCases.map { "\($0.rawValue): \($0.label)" } == [
            "settingUp: Setting up",
            "awaitingPermission: Waiting on you",
            "running: Agent running",
            "setupFailed: Setup failed",
            "unread: Unread",
            "merged: Merged",
            "closed: Pull request closed",
            "conflicted: Merge conflicts",
            "checksFailing: Checks failing",
            "checksRunning: Checks running",
            "checksPassed: Checks passed",
            "draft: Draft pull request",
            "pullRequestOpen: Pull request open",
            "changed: Has changes",
            "clean: No changes",
        ])
    }

    @Test("a pull request state's summary names it by number")
    func statusSummary() {
        let pullRequest = PullRequest(
            number: 42, title: "Work", url: "https://github.com/acme/app/pull/42", state: "OPEN"
        )
        #expect(WorkspaceStatus.pullRequestOpen.summary(pullRequest: pullRequest)
            == "Pull request open, pull request #42")
    }
}
