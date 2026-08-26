import Foundation

/// The same card, said about the pull request band in the title bar instead of about a sidebar
/// row.
///
/// The band is 380 points with a Create pull request button in it, so both its lines are cut:
/// `…t-question` over `No pull reque…`. The card is what those two lines say when they have room,
/// and the floor rather than the ceiling of what belongs on it.
///
/// **A second maker rather than a second card, and the same view draws both.** What changes is
/// which four facts land in the four slots, and every one of the changes is because the subject
/// changed: the row's card answers "what is this workspace", and this one answers "what is
/// happening to this branch on GitHub".
///
///   - The bold line is the pull request's own title where there is one, and the workspace's name
///     where there is not. It is the same question either way, which is what this change is
///     called, and before a pull request exists the only name it has is the workspace's.
///   - The state is `PullRequestStatus` rather than `WorkspaceStatus.label`, with local work
///     weighed in, so the card and the band it hangs off cannot give two answers. That is also
///     what puts "Local changes" on a card whose checks are green, which is the one state the band
///     tints amber and the sidebar's card has no vocabulary for.
///   - The mark is `WorkspaceStatus.ofBranch`, which is `resolve` with the agent left out. A
///     running agent and an unread turn are true of the workspace and are said on its row a few
///     inches to the left; over a band about a pull request they would be a mark answering a
///     different question.
///
/// **What was left out, deliberately.** The target branch once a pull request exists, because it
/// was chosen when the pull request was opened, is on GitHub, and is not the thing that changes
/// while somebody watches this band. Before then it is still a decision, so it is the detail under
/// "No pull request yet", which is where the band puts it too. The list of failing checks, because
/// the rollup already carries the number and a card with a list on it is a card that has to be
/// read rather than glanced at. The agent's own state, for the reason above. Reviewers, labels and
/// the author, because none of them is what this band is for and Bloom does not poll them.
public extension WorkspaceHoverCard {
    /// The card for the pull request band.
    ///
    /// - Parameter localWork: what the worktree is holding that GitHub has not got, which is the
    ///   same value the band tints itself from. Nil where it has not been read yet, and then the
    ///   card says what GitHub says, exactly as the band does.
    static func pullRequestBand(
        workspace: Workspace,
        pullRequest: PullRequest?,
        localWork: LocalWork? = nil,
        now: Date = Date()
    ) -> WorkspaceHoverCard {
        let resolved = verdict(
            workspace: workspace, pullRequest: pullRequest, localWork: localWork
        )

        return WorkspaceHoverCard(
            title: headline(workspace: workspace, pullRequest: pullRequest),
            branch: workspace.branch,
            diff: counts(for: workspace),
            status: resolved.status,
            state: resolved.state,
            detail: resolved.detail,
            pullRequest: reference(to: pullRequest),
            age: HomeAge.phrase(for: workspace.lastActivityAt, now: now)
        )
    }

    /// What this change is called. The pull request's title once there is one, because that is the
    /// name it has on GitHub and in every notification about it, and the workspace's name until
    /// then. A pull request whose title came back empty falls back rather than drawing a blank
    /// line where the biggest text on the card goes.
    private static func headline(workspace: Workspace, pullRequest: PullRequest?) -> String {
        let given = pullRequest?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return given.isEmpty ? workspace.name : given
    }

    /// The mark, the state in words, and the numbers behind it.
    ///
    /// Three things rather than one because they have to agree, and the case that forced saying so
    /// is local work. `PullRequestStatus` swaps the headline to "Local changes" when a green pull
    /// request is missing work that is still on this disk, and a green tick beside those two words
    /// is the card contradicting itself in the space of one line. So when the headline has been
    /// taken over, the mark is `changed`, which is what those words mean.
    private static func verdict(
        workspace: Workspace,
        pullRequest: PullRequest?,
        localWork: LocalWork?
    ) -> (status: WorkspaceStatus, state: String, detail: String?) {
        let mark = WorkspaceStatus.ofBranch(workspace: workspace, pullRequest: pullRequest)

        guard let pullRequest else {
            // The band's own two sentences, split into the two weights the card draws them in.
            // Word for word, because a reader who has just hovered a line is checking they read
            // it right, and a paraphrase is what makes them read it twice.
            return (
                mark,
                "No pull request yet",
                workspace.hasDiff
                    ? "Target \(workspace.baseBranch)"
                    : "Nothing has changed on this branch yet"
            )
        }

        let live = pullRequest.status(local: localWork)
        let tookOver = live.text != pullRequest.status.text
        // gh reports its own rollup, and for a failing run it is often the same words the state is
        // already set in. `WorkspaceStatus.detail` drops it there; this is the same rule, and it
        // is a rule rather than tidiness: the card said "Checks failing" twice before it was one.
        var detail = live.detail
        if let text = detail, text.isEmpty || text == live.text { detail = nil }

        return (tookOver ? .changed : mark, live.text, detail)
    }
}
