import SwiftUI
import BloomCore

/// The card that opens beside a hovered workspace row, in every state that has an edge on it.
///
/// The card is drawn in a panel of its own, which no probe in this folder can photograph and which
/// no pointer a capture run has can raise. What CAN be photographed is the card itself, and that
/// is what is worth looking at: the states are all differences of content, so a page of them side
/// by side answers every question except where the panel lands, and where the panel lands is
/// `HoverCardPlacement`, which the suite holds.
///
/// Each pane is the card at its real 320 point width, over the sidebar's own ground, so a card
/// and the pane it opens out of can be judged against each other.
///
///     Bloom --snapshot-gallery <dir> --gallery hover-card
struct WorkspaceHoverCardGallery: View {
    /// A fixed clock, so "6d ago" is six days ago in every capture rather than however long it is
    /// since somebody wrote this file.
    private static let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func workspace(
        name: String,
        branch: String,
        additions: Int = 0,
        deletions: Int = 0,
        unread: Bool = false,
        daysAgo: Double = 0
    ) -> Workspace {
        let touched = Self.now.addingTimeInterval(-daysAgo * 86_400)
        return Workspace(
            repoID: RepoID("bloom"),
            name: name,
            branch: branch,
            path: "/tmp/worktree",
            baseBranch: "main",
            createdAt: touched,
            lastActivityAt: touched,
            additions: additions,
            deletions: deletions,
            changedFiles: additions + deletions > 0 ? 12 : 0,
            unread: unread
        )
    }

    private func pullRequest(
        number: Int = 362,
        state: String = "OPEN",
        checks: PullRequest.Checks,
        summary: String,
        isDraft: Bool = false
    ) -> PullRequest {
        PullRequest(
            number: number,
            title: "Add a hover card to the sidebar",
            url: "https://github.com/spatie/bloom/pull/\(number)",
            state: state,
            isDraft: isDraft,
            checks: checks,
            checksSummary: summary
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.pane) {
            HStack(alignment: .top, spacing: Metrics.pane) {
                pane("Changes, no pull request", card(
                    workspace(
                        name: "Add a hover card to the sidebar",
                        branch: "freek/hover-card",
                        additions: 1_418,
                        deletions: 556,
                        daysAgo: 6
                    )
                ))
                pane("Checks failing", card(
                    workspace(
                        name: "Fix the flaky diff parser test",
                        branch: "agent/2026-08/fix-the-flaky-diff-parser-test",
                        additions: 42,
                        deletions: 9,
                        daysAgo: 1
                    ),
                    pullRequest: pullRequest(
                        checks: .failing, summary: "1 of 12 required checks failed"
                    )
                ))
                pane("Checks passed", card(
                    workspace(
                        name: "Quieten the running mark",
                        branch: "freek/quiet-running-mark",
                        additions: 88,
                        deletions: 210,
                        daysAgo: 0.4
                    ),
                    pullRequest: pullRequest(
                        number: 2_631, checks: .passing, summary: "12 checks passed"
                    )
                ))
            }

            HStack(alignment: .top, spacing: Metrics.pane) {
                pane("Nothing changed, never touched", card(
                    workspace(name: "Look at the release notes", branch: "freek/release-notes")
                ))
                pane("A name nobody meant to be a name", card(
                    workspace(
                        name: "Show me every place the technologies used in this project are "
                            + "configured, and say which of them are pinned to a version",
                        branch: "agent/show-me-every-place-the-technologies-used-in-this-project",
                        additions: 7,
                        deletions: 7,
                        daysAgo: 240
                    )
                ))
                pane("Merged, and long since", card(
                    workspace(
                        name: "Draw a file path in a sent turn as a file",
                        branch: "chat/file-pill-and-merge-scroll",
                        additions: 2_793,
                        deletions: 1_044,
                        daysAgo: 400
                    ),
                    pullRequest: pullRequest(
                        number: 23, state: "MERGED", checks: .passing, summary: "12 checks passed"
                    )
                ))
            }

            HStack(alignment: .top, spacing: Metrics.pane) {
                pane("Waiting on you", card(
                    workspace(
                        name: "Rename the old app everywhere",
                        branch: "freek/rename",
                        additions: 12,
                        deletions: 4,
                        unread: true,
                        daysAgo: 0.001
                    ),
                    isRunning: true,
                    isAwaitingPermission: true
                ))
                pane("Agent running, pull request open", card(
                    workspace(
                        name: "Split AppModel by subject",
                        branch: "agent/split-app-model",
                        additions: 903,
                        deletions: 12,
                        daysAgo: 0.02
                    ),
                    isRunning: true,
                    pullRequest: pullRequest(checks: .none, summary: "")
                ))
                pane("Draft", card(
                    workspace(
                        name: "Sketch the ocean chart",
                        branch: "freek/ocean",
                        additions: 300,
                        deletions: 12,
                        daysAgo: 21
                    ),
                    pullRequest: pullRequest(
                        number: 7, checks: .pending, summary: "3 of 12 checks running",
                        isDraft: true
                    )
                ))
            }
        }
        .padding(Metrics.pane)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The ground the card is judged against is whatever it floats over, which in the window is
        // the centre column rather than the sidebar. The panel's material is `.behindWindow` and
        // has nothing to blend with offscreen, so this is the honest half of the picture: the
        // layout, the ink and the truncation.
        .background(Palette.windowBackground)
    }

    private func card(
        _ workspace: Workspace,
        isRunning: Bool = false,
        isAwaitingPermission: Bool = false,
        pullRequest: PullRequest? = nil
    ) -> WorkspaceHoverCard {
        WorkspaceHoverCard.make(
            workspace: workspace,
            isRunning: isRunning,
            isAwaitingPermission: isAwaitingPermission,
            pullRequest: pullRequest,
            now: Self.now
        )
    }

    private func pane(_ title: String, _ card: WorkspaceHoverCard) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingWide) {
            Text(title)
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)

            // Drawn exactly as the panel draws it, rim and material and all, and with no shadow,
            // because the shadow is the panel's rather than the card's.
            WorkspaceHoverCardView(card: card)
        }
        .frame(width: WorkspaceHoverCardView.width, alignment: .leading)
    }
}

extension Gallery {
    /// The registry entry for this page. See `Gallery`.
    ///
    /// Nine cards in three rows, at the card's real width.
    static let hoverCard = Gallery(
        name: "hover-card",
        title: "Workspace hover card",
        size: CGSize(width: 1_120, height: 620),
        needsFocus: false,
        view: { _ in AnyView(WorkspaceHoverCardGallery()) }
    )
}
