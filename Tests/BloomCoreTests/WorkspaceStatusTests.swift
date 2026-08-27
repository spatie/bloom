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
        (
            name: "a conflict outranks its own green checks",
            json: #"{"number":1,"title":"t","url":"u","state":"OPEN","mergeable":"CONFLICTING","statusCheckRollup":[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"SUCCESS"}]}"#,
            expected: .conflicted
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
            name: "a check nobody has picked up is a warning, and says so in both lines",
            json: #"{"number":1,"title":"t","url":"u","state":"OPEN","statusCheckRollup":[{"__typename":"CheckRun","name":"a","status":"QUEUED"}]}"#,
            tone: .warning,
            text: "Checks queued", detail: "1 check queued", canMerge: true
        ),
        (
            name: "a check a runner has is a warning too, in the other vocabulary",
            json: #"{"number":1,"title":"t","url":"u","state":"OPEN","statusCheckRollup":[{"__typename":"CheckRun","name":"a","status":"IN_PROGRESS"}]}"#,
            tone: .warning,
            text: "Checks running", detail: "1 check running", canMerge: true
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

    /// The title is the one line a reader reliably reads, so it is the line that has to say who
    /// merges. Bloom does not: the request goes to the workspace's agent as an ordinary turn.
    @Test("the merge confirmation says who is going to do it")
    func mergeConfirmationNamesEverything() throws {
        let pullRequest = try decode(json(
            state: "OPEN",
            checks: #"{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"FAILURE","isRequired":true}"#
        ))

        #expect(pullRequest.mergeConfirmationTitle(base: "main")
            == "Ask the agent to merge #42 into main?")

        let text = pullRequest.mergeConfirmation(base: "main", deletesBranch: true)
        #expect(text.contains("feature/glyphs"))
        // A red check is repeated here rather than being hidden behind the button.
        #expect(text.contains("1 required check failed"))
        #expect(text.contains("agent"))
        // The app no longer runs the merge, so it no longer claims to be the thing that cannot
        // take it back.
        #expect(!text.contains("Bloom cannot undo this."))
        // The number, the title and the method are on the title line and on the button, and were
        // said a second time here for no gain.
        #expect(!text.contains("Better glyphs"))
        #expect(!text.contains("Squash and merge"))
    }

    /// One paragraph still, and both halves of what confirming actually does: a turn goes into the
    /// chat, and the branch on the server goes after the merge lands.
    @Test("a clean merge confirmation is one short paragraph")
    func mergeConfirmationIsShort() throws {
        let text = try decode(json(state: "OPEN")).mergeConfirmation(
            base: "main", deletesBranch: true
        )
        #expect(text == "This workspace's agent is asked to merge it, in the chat, so you see "
            + "every command it runs and it can tell you if GitHub refuses. Once the merge lands "
            + "it deletes feature/glyphs on GitHub, not here.")
        #expect(!text.contains("\n"))
    }

    @Test("a confirmation that does not delete the branch does not claim to")
    func confirmationWithoutBranchDeletion() throws {
        let text = try decode(json(state: "OPEN")).mergeConfirmation(
            base: "main", deletesBranch: false
        )
        #expect(!text.contains("is deleted on GitHub"))
        #expect(text.contains("asked to merge it, in the chat"))
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

/// The state the sidebar had no word for.
///
/// The band under the title bar said "Merge conflicts" in red, `PullRequest.status` had produced a
/// `.fixConflicts` remedy to draw the button beside it, and the row in the sidebar for the same
/// workspace drew a green tick, because the mark fell through the conflict to whatever CI last
/// said about a commit the base branch has since moved away from. So these tests are about where
/// the state sits against everything it can be true alongside, and about the two panes agreeing.
@Suite("Merge conflicts", .tags(.agentProtocol))
struct ConflictedStatusTests {
    /// Everything a conflict can be true at the same time as, and which of the two the row says.
    ///
    /// The order is `PullRequest.status`'s own, not a second one: a conflict is what a push cannot
    /// clear and what nothing but a person resolves, so it takes the row from the rollup and from
    /// the draft flag. What it does NOT take it from is a pull request that has already ended;
    /// gh's `mergeable` on a merged or closed pull request is a leftover about a branch nobody is
    /// landing, and "Merge conflicts" over a merged pull request would be an alarm about nothing.
    @Test("where a conflict sits against everything else GitHub reports", arguments: [
        (
            name: "outranks a green rollup",
            json: #"{"number":1,"title":"t","url":"u","state":"OPEN","mergeable":"CONFLICTING","statusCheckRollup":[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"SUCCESS"}]}"#,
            expected: WorkspaceStatus.conflicted
        ),
        (
            name: "outranks a failing rollup, which a push could clear and this cannot",
            json: #"{"number":1,"title":"t","url":"u","state":"OPEN","mergeable":"CONFLICTING","statusCheckRollup":[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"FAILURE","isRequired":true}]}"#,
            expected: .conflicted
        ),
        (
            name: "outranks checks that have not finished",
            json: #"{"number":1,"title":"t","url":"u","state":"OPEN","mergeable":"CONFLICTING","statusCheckRollup":[{"__typename":"CheckRun","name":"a","status":"IN_PROGRESS"}]}"#,
            expected: .conflicted
        ),
        (
            name: "outranks the draft flag, because a draft that conflicts still conflicts",
            json: #"{"number":1,"title":"t","url":"u","state":"OPEN","isDraft":true,"mergeable":"CONFLICTING","statusCheckRollup":[]}"#,
            expected: .conflicted
        ),
        (
            name: "an older gh calls the same thing DIRTY",
            json: #"{"number":1,"title":"t","url":"u","state":"OPEN","mergeStateStatus":"DIRTY","statusCheckRollup":[]}"#,
            expected: .conflicted
        ),
        (
            name: "merged wins, because the branch it conflicted with is landed",
            json: #"{"number":1,"title":"t","url":"u","state":"MERGED","mergeable":"CONFLICTING","statusCheckRollup":[]}"#,
            expected: .merged
        ),
        (
            name: "closed wins, for the same reason",
            json: #"{"number":1,"title":"t","url":"u","state":"CLOSED","mergeable":"CONFLICTING","statusCheckRollup":[]}"#,
            expected: .closed
        ),
        (
            name: "a pull request gh could not compute a merge for is not a conflicted one",
            json: #"{"number":1,"title":"t","url":"u","state":"OPEN","mergeable":"UNKNOWN","statusCheckRollup":[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"SUCCESS"}]}"#,
            expected: .checksPassed
        ),
    ])
    func precedence(name: String, json: String, expected: WorkspaceStatus) throws {
        #expect(try mark(json) == expected, "\(name)")
    }

    /// The agent still outranks it, like every other thing GitHub has to say. A conflict will keep
    /// until the turn ends; a running agent is the thing happening now.
    @Test("the workspace's own state still comes first")
    func localStateStillWins() throws {
        let conflicting = try decode(
            #"{"number":1,"title":"t","url":"u","state":"OPEN","mergeable":"CONFLICTING","statusCheckRollup":[]}"#
        )
        #expect(
            WorkspaceStatus.resolve(
                workspace: workspace(), isRunning: true, pullRequest: conflicting
            ) == .running
        )
        #expect(
            WorkspaceStatus.resolve(
                workspace: workspace(unread: true), isRunning: false, pullRequest: conflicting
            ) == .unread
        )
    }

    /// The bug, written down: one workspace, two panes, one verdict. `WorkspaceHoverCard`'s own
    /// suite covers the card; this is the mark the sidebar row draws against the words the band
    /// draws, which is the pair that disagreed.
    @Test("the row's mark and the band's headline say the same thing")
    func theTwoPanesAgree() throws {
        let conflicting = try decode(
            #"{"number":1,"title":"t","url":"u","state":"OPEN","mergeable":"CONFLICTING","statusCheckRollup":[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"SUCCESS"}]}"#
        )
        let mark = WorkspaceStatus.ofBranch(workspace: workspace(), pullRequest: conflicting)

        #expect(mark == .conflicted)
        #expect(mark.label == conflicting.status.text)
        #expect(conflicting.status.remedy == .fixConflicts)
    }

    /// It belongs in the legend's second half, which is generated from this property rather than
    /// from a list beside it, and its detail is the conflict rather than the rollup: "Merge
    /// conflicts, pull request #1: 12 checks passed" is a tooltip arguing with its own headline.
    @Test("it reads as a GitHub state, and its detail is about the conflict")
    func legendAndTooltip() throws {
        #expect(WorkspaceStatus.conflicted.describesPullRequest)
        #expect(WorkspaceStatus.conflicted.label == "Merge conflicts")

        let conflicting = try decode(
            #"{"number":7,"title":"t","url":"u","state":"OPEN","mergeable":"CONFLICTING","statusCheckRollup":[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"SUCCESS"}]}"#
        )
        let detail = WorkspaceStatus.conflicted.detail(pullRequest: conflicting)
        #expect(detail == "This branch conflicts with the base branch")

        let summary = WorkspaceStatus.conflicted.summary(pullRequest: conflicting)
        #expect(summary == "Merge conflicts, pull request #7: This branch conflicts with the base branch")
    }

    // MARK: - Fixtures

    private func mark(_ json: String) throws -> WorkspaceStatus {
        WorkspaceStatus.resolve(
            workspace: workspace(), isRunning: false, pullRequest: try decode(json)
        )
    }

    private func decode(_ json: String) throws -> PullRequest {
        try GitHub.decodePullRequest(from: Data(json.utf8))
    }

    private func workspace(unread: Bool = false) -> Workspace {
        Workspace(
            repoID: RepoID("repo"),
            name: "Glyphs",
            branch: "feature/glyphs",
            path: "/tmp/glyphs",
            baseBranch: "main",
            setupState: .succeeded,
            additions: 3,
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

    /// Waiting first, because it is the only segment whose number costs something to ignore. It is
    /// also the only one beside unread: the strip stopped counting running agents, since a filled
    /// circle and a filled hand are the same blob at menu bar size. See `MenuBarSummary.segments`.
    @Test("the menu bar puts waiting ahead of unread")
    func menuBar() {
        let segments = MenuBarSummary.segments(waiting: 2, unread: 1)

        #expect(segments.map(\.count) == [2, 1])
        #expect(segments.first?.symbolName == MenuBarSummary.waitingSymbol)
        #expect(segments.first?.label == "Agents waiting on you")
    }

    @Test("nothing waiting leaves the unread count on its own")
    func menuBarUnchanged() {
        #expect(MenuBarSummary.segments(waiting: 0, unread: 1)
            == [MenuBarSummary.Segment(
                symbolName: MenuBarSummary.unreadSymbol, count: 1, label: "Unread results"
            )])
        #expect(MenuBarSummary.tooltip(waiting: 0, unread: 1) == "1 unread result")
    }

    @Test("the tooltip says it in words, singular and plural")
    func tooltip() {
        #expect(MenuBarSummary.tooltip(waiting: 1, unread: 0) == "1 agent waiting on you")
        #expect(MenuBarSummary.tooltip(waiting: 2, unread: 0) == "2 agents waiting on you")
        #expect(MenuBarSummary.tooltip(waiting: 2, unread: 1)
            == "2 agents waiting on you, 1 unread result")
    }
}
