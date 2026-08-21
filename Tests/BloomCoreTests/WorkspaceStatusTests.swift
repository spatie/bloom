import Foundation
import Testing
@testable import BloomCore

/// The two mappings the sidebar mark and the inspector strip are built on.
///
/// Both are pure functions of a decoded `gh pr view` payload plus what the store already knows
/// about a workspace, so everything here is fixture JSON and structs. Nothing in this file may
/// reach for gh, a repository or the network: the point is that the decision can be pinned
/// without any of them.
@Suite("Workspace status", .tags(.agentProtocol))
struct WorkspaceStatusTests {

    // MARK: - Sidebar mark

    @Test("local state outranks anything GitHub says", arguments: [
        (
            name: "a running setup script wins over a merged pull request",
            setup: SetupState.running, running: true, unread: true, expected: WorkspaceStatus.settingUp
        ),
        (
            name: "an agent mid turn wins over a failed setup",
            setup: .failed, running: true, unread: true, expected: .running
        ),
        (
            name: "a failed setup wins over unread output",
            setup: .failed, running: false, unread: true, expected: .setupFailed
        ),
        (
            name: "unread output wins over the pull request",
            setup: .succeeded, running: false, unread: true, expected: .unread
        ),
    ])
    func localStateWins(
        name: String, setup: SetupState, running: Bool, unread: Bool, expected: WorkspaceStatus
    ) throws {
        let status = WorkspaceStatus.resolve(
            workspace: workspace(setup: setup, unread: unread, additions: 10),
            isRunning: running,
            pullRequest: try decode(json(state: "MERGED"))
        )
        #expect(status == expected, "\(name)")
    }

    @Test("a pull request decides the mark once the workspace is quiet", arguments: [
        (
            name: "merged",
            json: #"{"number":1,"title":"t","url":"u","state":"MERGED","statusCheckRollup":[]}"#,
            expected: WorkspaceStatus.merged
        ),
        (
            name: "closed without merging",
            json: #"{"number":1,"title":"t","url":"u","state":"CLOSED","statusCheckRollup":[]}"#,
            expected: .closed
        ),
        (
            name: "draft outranks its own green checks",
            json: #"{"number":1,"title":"t","url":"u","state":"OPEN","isDraft":true,"statusCheckRollup":[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"SUCCESS"}]}"#,
            expected: .draft
        ),
        (
            name: "a required failure",
            json: #"{"number":1,"title":"t","url":"u","state":"OPEN","statusCheckRollup":[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"FAILURE","isRequired":true}]}"#,
            expected: .checksFailing
        ),
        (
            name: "still running",
            json: #"{"number":1,"title":"t","url":"u","state":"OPEN","statusCheckRollup":[{"__typename":"CheckRun","name":"a","status":"IN_PROGRESS"}]}"#,
            expected: .checksRunning
        ),
        (
            name: "green",
            json: #"{"number":1,"title":"t","url":"u","state":"OPEN","statusCheckRollup":[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"SUCCESS"}]}"#,
            expected: .checksPassed
        ),
        (
            name: "open with no checks configured",
            json: #"{"number":1,"title":"t","url":"u","state":"OPEN","statusCheckRollup":[]}"#,
            expected: .pullRequestOpen
        ),
    ])
    func pullRequestDecides(name: String, json: String, expected: WorkspaceStatus) throws {
        let status = WorkspaceStatus.resolve(
            workspace: workspace(additions: 3),
            isRunning: false,
            pullRequest: try decode(json)
        )
        #expect(status == expected, "\(name)")
    }

    @Test("without a pull request the worktree decides")
    func worktreeDecides() {
        let changed = WorkspaceStatus.resolve(
            workspace: workspace(additions: 12, deletions: 1), isRunning: false, pullRequest: nil
        )
        let clean = WorkspaceStatus.resolve(
            workspace: workspace(), isRunning: false, pullRequest: nil
        )
        #expect(changed == .changed)
        #expect(clean == .clean)
    }

    /// gh missing, gh signed out and "this branch has no pull request" all arrive as nil, and the
    /// mark has to stay a plain statement about the worktree rather than becoming a warning.
    @Test("a missing pull request never turns into a bad one")
    func missingPullRequestIsNotAFailure() {
        for state in [SetupState.succeeded, .skipped, .pending] {
            let status = WorkspaceStatus.resolve(
                workspace: workspace(setup: state, additions: 4), isRunning: false, pullRequest: nil
            )
            #expect(status == .changed)
        }
    }

    @Test("every state says what it is, and pull request states carry the number")
    func descriptions() throws {
        for status in WorkspaceStatus.allCases {
            #expect(!status.label.isEmpty)
            // One documented exception. The raised hand is the only mark in the column that asks
            // for something rather than reporting something, and "Waiting on you" does not say
            // what it is waiting for or that the agent has stopped. The tooltip is where that is
            // learned, so it is a sentence rather than the label again.
            guard status != .awaitingPermission else {
                #expect(status.summary(pullRequest: nil) != status.label)
                #expect(status.summary(pullRequest: nil).contains("cannot go on until you answer"))
                continue
            }
            #expect(status.summary(pullRequest: nil) == status.label)
        }

        let pullRequest = try decode(json(
            state: "OPEN",
            checks: #"{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"FAILURE","isRequired":true}"#
        ))
        let summary = WorkspaceStatus.checksFailing.summary(pullRequest: pullRequest)
        #expect(summary.contains("#42"))
        #expect(summary.contains("1 required check failed"))
    }

    // MARK: - Inspector strip

    @Test("the strip's headline, tone and merge button follow the pull request", arguments: [
        (
            name: "green checks are ready to merge, with the count underneath",
            json: #"{"number":1,"title":"t","url":"u","state":"OPEN","statusCheckRollup":[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"SUCCESS"}]}"#,
            tone: PullRequestStatus.Tone.positive,
            text: "Ready to merge", detail: "1 check passed" as String?, canMerge: true
        ),
        (
            name: "an optional failure does not change the headline, only the detail",
            json: #"{"number":1,"title":"t","url":"u","state":"OPEN","statusCheckRollup":[{"__typename":"StatusContext","context":"preview","state":"FAILURE","isRequired":false}]}"#,
            tone: .positive,
            text: "Ready to merge", detail: "1 optional check failed", canMerge: true
        ),
        (
            name: "a required failure is negative but still mergeable by hand",
            json: #"{"number":1,"title":"t","url":"u","state":"OPEN","statusCheckRollup":[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"FAILURE","isRequired":true}]}"#,
            tone: .negative,
            text: "Checks failing", detail: "1 required check failed", canMerge: true
        ),
        (
            name: "pending checks are a warning",
            json: #"{"number":1,"title":"t","url":"u","state":"OPEN","statusCheckRollup":[{"__typename":"CheckRun","name":"a","status":"QUEUED"}]}"#,
            tone: .warning,
            text: "Checks running", detail: "1 check pending", canMerge: true
        ),
        (
            name: "changes requested is a warning even with green checks",
            json: #"{"number":1,"title":"t","url":"u","state":"OPEN","reviewDecision":"CHANGES_REQUESTED","statusCheckRollup":[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"SUCCESS"}]}"#,
            tone: .warning,
            text: "Changes requested", detail: "1 check passed", canMerge: true
        ),
        (
            name: "a review nobody has done yet is a warning, not a green light",
            json: #"{"number":1,"title":"t","url":"u","state":"OPEN","reviewDecision":"REVIEW_REQUIRED","statusCheckRollup":[]}"#,
            tone: .warning,
            text: "Waiting for review", detail: nil, canMerge: true
        ),
        (
            name: "a pull request with no checks at all is still ready, and says nothing more",
            json: #"{"number":1,"title":"t","url":"u","state":"OPEN","statusCheckRollup":[]}"#,
            tone: .positive,
            text: "Ready to merge", detail: nil, canMerge: true
        ),
        (
            name: "a draft cannot be merged",
            json: #"{"number":1,"title":"t","url":"u","state":"OPEN","isDraft":true,"statusCheckRollup":[]}"#,
            tone: .neutral,
            text: "Draft", detail: nil, canMerge: false
        ),
        (
            name: "conflicts outrank green checks",
            json: #"{"number":1,"title":"t","url":"u","state":"OPEN","mergeable":"CONFLICTING","statusCheckRollup":[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"SUCCESS"}]}"#,
            tone: .negative,
            text: "Merge conflicts",
            detail: "This branch conflicts with the base branch", canMerge: false
        ),
        (
            name: "an older gh reports the same conflict as DIRTY",
            json: #"{"number":1,"title":"t","url":"u","state":"OPEN","mergeStateStatus":"DIRTY","statusCheckRollup":[]}"#,
            tone: .negative,
            text: "Merge conflicts",
            detail: "This branch conflicts with the base branch", canMerge: false
        ),
        (
            name: "a merged pull request is done, not mergeable",
            json: #"{"number":1,"title":"t","url":"u","state":"MERGED","statusCheckRollup":[]}"#,
            tone: .merged, text: "Merged", detail: nil, canMerge: false
        ),
        (
            name: "a closed one is quiet",
            json: #"{"number":1,"title":"t","url":"u","state":"CLOSED","statusCheckRollup":[]}"#,
            tone: .neutral, text: "Closed", detail: nil, canMerge: false
        ),
    ])
    func stripPresentation(
        name: String,
        json: String,
        tone: PullRequestStatus.Tone,
        text: String,
        detail: String?,
        canMerge: Bool
    ) throws {
        let status = try decode(json).status
        #expect(status.tone == tone, "\(name)")
        #expect(status.text == text, "\(name)")
        #expect(status.detail == detail, "\(name)")
        #expect(status.canMerge == canMerge, "\(name)")
    }

    /// A greyed out button with no explanation is the thing this is meant to prevent.
    @Test("everything that blocks merging explains itself")
    func blockedReasons() throws {
        let blocked = [
            #"{"number":1,"title":"t","url":"u","state":"OPEN","isDraft":true,"statusCheckRollup":[]}"#,
            #"{"number":1,"title":"t","url":"u","state":"OPEN","mergeable":"CONFLICTING","statusCheckRollup":[]}"#,
            #"{"number":1,"title":"t","url":"u","state":"MERGED","statusCheckRollup":[]}"#,
            #"{"number":1,"title":"t","url":"u","state":"CLOSED","statusCheckRollup":[]}"#,
        ]
        for json in blocked {
            let status = try decode(json).status
            #expect(status.canMerge == false)
            #expect(status.blockedReason?.isEmpty == false)
        }

        let open = try decode(json(state: "OPEN")).status
        #expect(open.canMerge)
        #expect(open.blockedReason == nil)
    }

    @Test("gh reports the branch merging will delete")
    func decodesHeadBranch() throws {
        #expect(try decode(json(state: "OPEN")).branch == "feature/glyphs")
        // An older gh omits the field, and an empty branch is better than a guessed one.
        #expect(try decode(
            #"{"number":1,"title":"t","url":"u","state":"OPEN","statusCheckRollup":[]}"#
        ).branch.isEmpty)
    }

    @Test("the merge confirmation names what it is about to do")
    func mergeConfirmationNamesEverything() throws {
        let pullRequest = try decode(json(
            state: "OPEN",
            checks: #"{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"FAILURE","isRequired":true}"#
        ))

        #expect(pullRequest.mergeConfirmationTitle(base: "main") == "Merge #42 into main?")

        let text = pullRequest.mergeConfirmation(base: "main", deletesBranch: true)
        #expect(text.contains("feature/glyphs"))
        // A red check is repeated here rather than being hidden behind the button.
        #expect(text.contains("1 required check failed"))
        #expect(text.contains("Bloom cannot undo this."))
        // The number, the title and the method are on the title line and on the button, and were
        // said a second time here for no gain. The dialog is the two facts that change the answer.
        #expect(!text.contains("Better glyphs"))
        #expect(!text.contains("Squash and merge"))
    }

    /// Four paragraphs became one, and the worktree reassurance became the clause that keeps the
    /// branch deletion from reading as a threat to the copy on this machine.
    @Test("a clean merge confirmation is one short paragraph")
    func mergeConfirmationIsShort() throws {
        let text = try decode(json(state: "OPEN")).mergeConfirmation(
            base: "main", deletesBranch: true
        )
        #expect(text == "The branch feature/glyphs is deleted on GitHub, not here. "
            + "Bloom cannot undo this.")
        #expect(!text.contains("\n"))
    }

    @Test("a confirmation that does not delete the branch does not claim to")
    func confirmationWithoutBranchDeletion() throws {
        let text = try decode(json(state: "OPEN")).mergeConfirmation(
            base: "main", deletesBranch: false
        )
        #expect(!text.contains("is deleted on GitHub"))
        #expect(text == "Bloom cannot undo this.")
    }

    // MARK: - Fixtures

    private func decode(_ json: String) throws -> PullRequest {
        try GitHub.decodePullRequest(from: Data(json.utf8))
    }

    private func json(state: String, checks: String = "") -> String {
        """
        {"number":42,"title":"Better glyphs","url":"https://github.com/acme/app/pull/42",
        "state":"\(state)","isDraft":false,"headRefName":"feature/glyphs",
        "statusCheckRollup":[\(checks)]}
        """
    }

    private func workspace(
        setup: SetupState = .succeeded,
        unread: Bool = false,
        additions: Int = 0,
        deletions: Int = 0
    ) -> Workspace {
        Workspace(
            repoID: RepoID("repo"),
            name: "Glyphs",
            branch: "feature/glyphs",
            path: "/tmp/glyphs",
            baseBranch: "main",
            setupState: setup,
            additions: additions,
            deletions: deletions,
            unread: unread
        )
    }
}

/// The sixth signal: a workspace whose agent has stopped and is waiting on a person.
///
/// The whole reason it exists is that a blocked workspace must not look like a working one. So the
/// tests are about precedence and about the numbers that leave the workspace, not about the shape
/// of the mark.
@Suite("Waiting on you")
struct AwaitingPermissionStatusTests {
    private func workspace(unread: Bool = false, additions: Int = 0) -> Workspace {
        Workspace(
            repoID: RepoID("r"), name: "w", branch: "b", path: "/tmp/w", baseBranch: "main",
            setupState: .succeeded, additions: additions, unread: unread
        )
    }

    /// The one state that outranks running. An agent that is working needs nothing; an agent that
    /// is blocked is the only row in the column where time is being wasted.
    @Test("waiting outranks running")
    func outranksRunning() {
        let status = WorkspaceStatus.resolve(
            workspace: workspace(unread: true, additions: 9),
            isRunning: true,
            pullRequest: nil,
            isAwaitingPermission: true
        )

        #expect(status == .awaitingPermission)
        #expect(status.needsAnswer)
    }

    /// Setup is still ahead of it, and deliberately: a workspace whose setup script has not
    /// finished cannot be trusted to say anything about itself yet.
    @Test("a workspace still setting up says so first")
    func setupWinsOverWaiting() {
        var setting = workspace()
        setting.apply(.runStarted)
        let status = WorkspaceStatus.resolve(
            workspace: setting, isRunning: true, pullRequest: nil, isAwaitingPermission: true
        )

        #expect(status == .settingUp)
    }

    /// Every existing caller keeps its meaning without knowing the state exists.
    @Test("nothing changes for a workspace nobody is waiting on")
    func defaultsToFalse() {
        let workspace = workspace(additions: 3)

        #expect(WorkspaceStatus.resolve(workspace: workspace, isRunning: false, pullRequest: nil) == .changed)
        #expect(WorkspaceStatus.resolve(workspace: workspace, isRunning: true, pullRequest: nil) == .running)
    }

    @Test("only the waiting state asks for an answer")
    func onlyOneStateNeedsAnswering() {
        #expect(WorkspaceStatus.allCases.filter(\.needsAnswer) == [.awaitingPermission])
    }

    // MARK: What leaves the workspace

    /// The badge is one number and has to mean one thing. An unread result will still be there in
    /// an hour; a blocked agent is burning the hour, so it wins rather than being added.
    @Test("the dock badge counts waiting ahead of unread, and never sums them")
    func dockBadge() {
        #expect(DockBadge.label(unread: 4, waiting: 2, isEnabled: true) == "2")
        #expect(DockBadge.label(unread: 4, waiting: 0, isEnabled: true) == "4")
        #expect(DockBadge.label(unread: 0, waiting: 3, isEnabled: true) == "3")
        // Not "6".
        #expect(DockBadge.label(unread: 4, waiting: 2, isEnabled: true) != "6")
        // Nothing at all is still nothing at all.
        #expect(DockBadge.label(unread: 0, waiting: 0, isEnabled: true) == nil)
        // And the preference still switches the whole thing off.
        #expect(DockBadge.label(unread: 4, waiting: 2, isEnabled: false) == nil)
    }

    @Test("the badge counts workspaces, not questions")
    func waitingCount() {
        let blocked = workspace()
        let working = workspace()
        let count = DockBadge.waitingCount(in: [blocked, working, working]) { $0.id == blocked.id }

        #expect(count == 1)
    }

    /// Waiting first, because it is the only segment whose number costs something to ignore.
    @Test("the menu bar puts waiting ahead of running")
    func menuBar() {
        let segments = MenuBarSummary.segments(running: 3, unread: 1, waiting: 2)

        #expect(segments.map(\.count) == [2, 3, 1])
        #expect(segments.first?.symbolName == MenuBarSummary.waitingSymbol)
        #expect(segments.first?.label == "Agents waiting on you")
    }

    @Test("nothing waiting leaves the strip exactly as it was")
    func menuBarUnchanged() {
        #expect(MenuBarSummary.segments(running: 3, unread: 1, waiting: 0)
            == MenuBarSummary.segments(running: 3, unread: 1))
        #expect(MenuBarSummary.tooltip(running: 3, unread: 1, waiting: 0)
            == MenuBarSummary.tooltip(running: 3, unread: 1))
    }

    @Test("the tooltip says it in words, singular and plural")
    func tooltip() {
        #expect(MenuBarSummary.tooltip(running: 0, unread: 0, waiting: 1) == "1 agent waiting on you")
        #expect(MenuBarSummary.tooltip(running: 0, unread: 0, waiting: 2) == "2 agents waiting on you")
        #expect(MenuBarSummary.tooltip(running: 1, unread: 0, waiting: 2)
            == "2 agents waiting on you, 1 agent running")
    }
}
