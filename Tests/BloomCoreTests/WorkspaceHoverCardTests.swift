import CoreGraphics
import Foundation
import Testing
@testable import BloomCore

/// What the card beside a hovered sidebar row says, and where it is put.
///
/// Every date here is built rather than read off the clock, for the reason `HomeListTests` writes
/// down: a suite that says "six days ago" as an offset from `Date()` passes all afternoon and
/// fails at midnight.
@Suite("Workspace hover card")
struct WorkspaceHoverCardTests {
    /// The clock every case below is measured from. A fixed instant, so "6d ago" is 6d ago on
    /// every machine that runs this and in every month.
    static let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func workspace(
        name: String = "Add a hover card to the sidebar",
        branch: String = "freek/hover-card",
        additions: Int = 0,
        deletions: Int = 0,
        changedFiles: Int = 0,
        unread: Bool = false,
        lastActivityAt: Date = WorkspaceHoverCardTests.now
    ) -> Workspace {
        Workspace(
            repoID: RepoID("repo"),
            name: name,
            branch: branch,
            path: "/tmp/worktree",
            baseBranch: "main",
            createdAt: lastActivityAt,
            lastActivityAt: lastActivityAt,
            additions: additions,
            deletions: deletions,
            changedFiles: changedFiles,
            unread: unread
        )
    }

    private func pullRequest(
        number: Int = 362,
        state: String = "OPEN",
        checks: PullRequest.Checks = .none,
        checksSummary: String = "",
        isDraft: Bool = false
    ) -> PullRequest {
        PullRequest(
            number: number,
            title: "Add a hover card to the sidebar",
            url: "https://github.com/spatie/bloom/pull/\(number)",
            state: state,
            isDraft: isDraft,
            checks: checks,
            checksSummary: checksSummary
        )
    }

    // MARK: - What it says

    @Test("A changed workspace with no pull request says so and shows its counts")
    func changedWithoutPullRequest() {
        let card = WorkspaceHoverCard.make(
            workspace: workspace(additions: 1_418, deletions: 556, changedFiles: 12),
            now: Self.now
        )

        #expect(card.title == "Add a hover card to the sidebar")
        #expect(card.branch == "freek/hover-card")
        #expect(card.diff == WorkspaceHoverCard.Diff(additions: 1_418, deletions: 556))
        #expect(card.status == .changed)
        #expect(card.state == "Has changes")
        #expect(card.detail == nil)
        #expect(card.pullRequest == nil)
    }

    /// The empty case, and the reason `diff` is optional rather than two zeroes: "+0 -0" is a
    /// line that says nothing, so the card has to have something else to draw there.
    @Test("A workspace with nothing changed carries no counts at all")
    func noChanges() {
        let card = WorkspaceHoverCard.make(workspace: workspace(), now: Self.now)

        #expect(card.diff == nil)
        #expect(card.status == .clean)
        #expect(card.state == "No changes")
        #expect(WorkspaceHoverCard.noChanges == "No changes")
    }

    /// Files touched without a line changing, which is what a rename or a mode change is. The
    /// card follows `Workspace.hasDiff` rather than `changedFiles`, so it holds exactly the
    /// opinion the row's own counts hold: two files and nothing to count is not a diff.
    @Test("Changed files with no changed lines draw no counts")
    func zeroLineDiff() {
        let card = WorkspaceHoverCard.make(
            workspace: workspace(changedFiles: 2), now: Self.now
        )

        #expect(card.status == .clean)
        #expect(card.diff == nil)
    }

    @Test("Failing checks put the count behind the state rather than in place of it")
    func failingChecks() {
        let card = WorkspaceHoverCard.make(
            workspace: workspace(additions: 40, deletions: 3, changedFiles: 2),
            pullRequest: pullRequest(
                checks: .failing, checksSummary: "1 of 12 checks failed"
            ),
            now: Self.now
        )

        #expect(card.status == .checksFailing)
        #expect(card.state == "Checks failing")
        #expect(card.detail == "1 of 12 checks failed")
        #expect(card.pullRequest?.number == 362)
        #expect(card.pullRequest?.url == "https://github.com/spatie/bloom/pull/362")
    }

    /// gh reports its own rollup summary, and for a failing run it is often the same three words
    /// the state is already drawn in. The card must not say it twice.
    @Test("A rollup summary equal to the state is not repeated under it")
    func detailThatRepeatsTheState() {
        let card = WorkspaceHoverCard.make(
            workspace: workspace(additions: 40, deletions: 3, changedFiles: 2),
            pullRequest: pullRequest(checks: .failing, checksSummary: "Checks failing"),
            now: Self.now
        )

        #expect(card.state == "Checks failing")
        #expect(card.detail == nil)
    }

    /// The state is about now and the number is about the branch. Suppressing the number while a
    /// turn runs would blink it out at the one moment somebody most wants to see it.
    @Test("A running agent keeps the pull request number under a running state")
    func runningKeepsItsPullRequest() {
        let card = WorkspaceHoverCard.make(
            workspace: workspace(additions: 12, deletions: 1, changedFiles: 1),
            isRunning: true,
            pullRequest: pullRequest(checks: .passing, checksSummary: "12 checks passed"),
            now: Self.now
        )

        #expect(card.status == .running)
        #expect(card.state == "Agent running")
        // The detail belongs to the pull request's state, and the state on show is not the pull
        // request's, so there is nothing to put behind it.
        #expect(card.detail == nil)
        #expect(card.pullRequest?.number == 362)
    }

    @Test("A blocked agent outranks everything else the row could say")
    func awaitingPermission() {
        let card = WorkspaceHoverCard.make(
            workspace: workspace(additions: 4, deletions: 0, changedFiles: 1, unread: true),
            isRunning: true,
            isAwaitingPermission: true,
            now: Self.now
        )

        #expect(card.status == .awaitingPermission)
        #expect(card.state == "Waiting on you")
    }

    // MARK: - The two things the row cannot draw

    /// The card exists because the row truncates. Shortening the name here as well would leave
    /// the whole affordance with nothing to add.
    @Test("A title far too long for the row is carried whole")
    func longTitle() {
        let long = "Show me every place the technologies used in this project are configured, "
            + "and say which of them are pinned to a version"
        let card = WorkspaceHoverCard.make(workspace: workspace(name: long), now: Self.now)

        #expect(card.title == long)
        #expect(card.title.count == long.count)
    }

    /// Never reduced to its last component: `freek/fix-checks` and `agent/fix-checks` would then
    /// draw the same line on two different workspaces.
    @Test("A branch with slashes in it keeps all of them")
    func branchWithSlashes() {
        let card = WorkspaceHoverCard.make(
            workspace: workspace(branch: "agent/2026-08/fix-the-checks"), now: Self.now
        )

        #expect(card.branch == "agent/2026-08/fix-the-checks")
    }

    // MARK: - Age

    @Test("Six days reads as the phrase, not as the measurement")
    func sixDaysAgo() {
        let card = WorkspaceHoverCard.make(
            workspace: workspace(lastActivityAt: Self.now.addingTimeInterval(-6 * 86_400)),
            now: Self.now
        )

        #expect(card.age == "6d ago")
    }

    /// A workspace nobody has touched since it was cut. `lastActivityAt` equals `createdAt`,
    /// which is the clock, and "now ago" is not English.
    @Test("A workspace that has never been touched reads as just now")
    func neverTouched() {
        let card = WorkspaceHoverCard.make(workspace: workspace(), now: Self.now)

        #expect(card.age == "just now")
    }

    /// A clock change or a restore from a backup produces a timestamp in the future. `HomeAge`
    /// already decided what to say about it, and the phrase must not invent a second answer.
    @Test("A timestamp from the future reads as just now rather than as a negative age")
    func futureTimestamp() {
        let card = WorkspaceHoverCard.make(
            workspace: workspace(lastActivityAt: Self.now.addingTimeInterval(3_600)),
            now: Self.now
        )

        #expect(card.age == "just now")
    }

    /// Every rung of `HomeAge`'s scale, so a change to one of its thresholds cannot quietly
    /// change what the card reads. Written out as a typed property rather than as a literal in
    /// the macro's argument list, which on its own was enough to time the type checker out
    /// inside the `@Test` expansion.
    static let ageRungs: [(seconds: Double, phrase: String)] = [
        (30, "just now"),
        (600, "10m ago"),
        (7_200, "2h ago"),
        (86_400 * 3, "3d ago"),
        (86_400 * 14, "2w ago"),
        (86_400 * 90, "3mo ago"),
        (86_400 * 800, "2y ago"),
    ]

    @Test("Every rung of the age scale gains the word", arguments: ageRungs)
    func agePhrases(rung: (seconds: Double, phrase: String)) {
        let card = WorkspaceHoverCard.make(
            workspace: workspace(lastActivityAt: Self.now.addingTimeInterval(-rung.seconds)),
            now: Self.now
        )

        #expect(card.age == rung.phrase)
    }

    // MARK: - Where it goes

    /// The ordinary case: a window in the middle of a large screen, sidebar row on the left.
    @Test("The card stands to the right of the row, its top edge on the row's")
    func placedRightOfTheRow() {
        let screen = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let row = CGRect(x: 200, y: 800, width: 240, height: 32)

        let frame = HoverCardPlacement.frame(
            anchor: row, size: CGSize(width: 300, height: 140), visible: screen
        )

        #expect(frame.minX == row.maxX + HoverCardPlacement.gap)
        #expect(frame.maxY == row.maxY)
    }

    /// A window pushed against the right edge of the screen, which is where a wide window with a
    /// collapsed inspector sits.
    @Test("With no room on the right the card flips to the left of the row")
    func flipsWhenTheRightIsFull() {
        let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let row = CGRect(x: 1_100, y: 400, width: 240, height: 32)

        let frame = HoverCardPlacement.frame(
            anchor: row, size: CGSize(width: 300, height: 140), visible: screen
        )

        #expect(frame.maxX == row.minX - HoverCardPlacement.gap)
        #expect(frame.minX >= screen.minX + HoverCardPlacement.screenMargin)
    }

    /// A screen with room for the card on neither side. Flipping would trade one overhang for
    /// another, so the card stays where it was and is pushed back inside instead.
    @Test("With room on neither side the card is clamped rather than flipped")
    func clampedWhenNeitherSideFits() {
        let screen = CGRect(x: 0, y: 0, width: 700, height: 500)
        let row = CGRect(x: 200, y: 300, width: 240, height: 32)

        let frame = HoverCardPlacement.frame(
            anchor: row, size: CGSize(width: 300, height: 140), visible: screen
        )

        #expect(frame.maxX == screen.maxX - HoverCardPlacement.screenMargin)
        #expect(frame.minX >= screen.minX + HoverCardPlacement.screenMargin)
    }

    /// The last row of a full sidebar. Running off the bottom would cut off the age and the pull
    /// request number, which are the two things on the card's last line.
    @Test("A row near the bottom of the screen pushes the card back up")
    func clampedAtTheBottom() {
        let screen = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let row = CGRect(x: 200, y: 20, width: 240, height: 32)

        let frame = HoverCardPlacement.frame(
            anchor: row, size: CGSize(width: 300, height: 140), visible: screen
        )

        #expect(frame.minY == screen.minY + HoverCardPlacement.screenMargin)
        #expect(frame.maxY <= screen.maxY - HoverCardPlacement.screenMargin)
    }

    /// A screen whose origin is not zero, which is every second display on this Mac. The margins
    /// are against that screen's own bounds, not against the desktop's.
    @Test("A row at the top of a screen with a non-zero origin stays on that screen")
    func clampedAtTheTopOfASecondScreen() {
        let screen = CGRect(x: -1_440, y: 200, width: 1_440, height: 900)
        let row = CGRect(x: -1_300, y: 1_064, width: 240, height: 32)

        let frame = HoverCardPlacement.frame(
            anchor: row, size: CGSize(width: 300, height: 140), visible: screen
        )

        #expect(frame.maxY <= screen.maxY - HoverCardPlacement.screenMargin)
        #expect(frame.minY >= screen.minY + HoverCardPlacement.screenMargin)
    }

    /// A card taller than the space it is given cannot satisfy both clamps. The TOP edge wins,
    /// because the title and the branch are drawn on it and the age at the foot is the one line
    /// worth losing. This is the whole reason the vertical clamps are applied in the order they
    /// are: the last one applied is the one that holds.
    @Test("A card taller than the screen keeps its top edge on screen")
    func tallerThanTheScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1_920, height: 300)
        let row = CGRect(x: 200, y: 100, width: 240, height: 32)

        let frame = HoverCardPlacement.frame(
            anchor: row, size: CGSize(width: 300, height: 600), visible: screen
        )

        #expect(frame.maxY == screen.maxY - HoverCardPlacement.screenMargin)
    }
}
