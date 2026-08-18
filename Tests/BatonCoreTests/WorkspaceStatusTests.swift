import Foundation
import Testing
@testable import BatonCore

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

    @Test("the strip's tone, sentence and merge button follow the pull request", arguments: [
        (
            name: "green checks are positive and mergeable",
            json: #"{"number":1,"title":"t","url":"u","state":"OPEN","statusCheckRollup":[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"SUCCESS"}]}"#,
            tone: PullRequestStatus.Tone.positive, text: "1 check passed", canMerge: true
        ),
        (
            name: "an optional failure stays positive, and says so",
            json: #"{"number":1,"title":"t","url":"u","state":"OPEN","statusCheckRollup":[{"__typename":"StatusContext","context":"preview","state":"FAILURE","isRequired":false}]}"#,
            tone: .positive, text: "1 optional check failed", canMerge: true
        ),
        (
            name: "a required failure is negative but still mergeable by hand",
            json: #"{"number":1,"title":"t","url":"u","state":"OPEN","statusCheckRollup":[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"FAILURE","isRequired":true}]}"#,
            tone: .negative, text: "1 required check failed", canMerge: true
        ),
        (
            name: "pending checks are a warning",
            json: #"{"number":1,"title":"t","url":"u","state":"OPEN","statusCheckRollup":[{"__typename":"CheckRun","name":"a","status":"QUEUED"}]}"#,
            tone: .warning, text: "1 check pending", canMerge: true
        ),
        (
            name: "changes requested is a warning even with green checks",
            json: #"{"number":1,"title":"t","url":"u","state":"OPEN","reviewDecision":"CHANGES_REQUESTED","statusCheckRollup":[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"SUCCESS"}]}"#,
            tone: .warning, text: "1 check passed", canMerge: true
        ),
        (
            name: "a draft cannot be merged",
            json: #"{"number":1,"title":"t","url":"u","state":"OPEN","isDraft":true,"statusCheckRollup":[]}"#,
            tone: .neutral, text: "No checks", canMerge: false
        ),
        (
            name: "conflicts outrank green checks",
            json: #"{"number":1,"title":"t","url":"u","state":"OPEN","mergeable":"CONFLICTING","statusCheckRollup":[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"SUCCESS"}]}"#,
            tone: .negative, text: "Conflicts with the base branch", canMerge: false
        ),
        (
            name: "an older gh reports the same conflict as DIRTY",
            json: #"{"number":1,"title":"t","url":"u","state":"OPEN","mergeStateStatus":"DIRTY","statusCheckRollup":[]}"#,
            tone: .negative, text: "Conflicts with the base branch", canMerge: false
        ),
        (
            name: "a merged pull request is done, not mergeable",
            json: #"{"number":1,"title":"t","url":"u","state":"MERGED","statusCheckRollup":[]}"#,
            tone: .accent, text: "Merged", canMerge: false
        ),
        (
            name: "a closed one is quiet",
            json: #"{"number":1,"title":"t","url":"u","state":"CLOSED","statusCheckRollup":[]}"#,
            tone: .neutral, text: "Closed", canMerge: false
        ),
    ])
    func stripPresentation(
        name: String, json: String, tone: PullRequestStatus.Tone, text: String, canMerge: Bool
    ) throws {
        let status = try decode(json).status
        #expect(status.tone == tone, "\(name)")
        #expect(status.text == text, "\(name)")
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

        let text = pullRequest.mergeConfirmation(
            method: .squash, base: "main", deletesBranch: true
        )
        #expect(text.contains("Squash and merge"))
        #expect(text.contains("#42"))
        #expect(text.contains("Better glyphs"))
        #expect(text.contains("feature/glyphs"))
        #expect(text.contains("main"))
        // A red check is repeated here rather than being hidden behind the button.
        #expect(text.contains("1 required check failed"))
        #expect(text.contains("Baton cannot undo this."))
    }

    @Test("a confirmation that does not delete the branch does not claim to")
    func confirmationWithoutBranchDeletion() throws {
        let text = try decode(json(state: "OPEN")).mergeConfirmation(
            method: .merge, base: "main", deletesBranch: false
        )
        #expect(!text.contains("is deleted on GitHub"))
        #expect(text.contains("Merge commit"))
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
            repoID: "repo",
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
