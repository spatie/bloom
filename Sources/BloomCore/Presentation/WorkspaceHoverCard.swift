import Foundation

/// Everything the card below the pull request band says, decided once.
///
/// It is a value in the core rather than a `body` in the view for the reason the three targets
/// exist: the states worth getting right are a workspace with no pull request, one whose checks
/// have failed, one with nothing changed at all, one nobody has touched, and a title too long to
/// draw, and none of those can be asserted on from a test target that has no view layer in it.
public struct WorkspaceHoverCard: Sendable, Hashable {
    /// The counts, or nil when the worktree matches its base and there is nothing to count.
    ///
    /// Nil rather than two zeroes, because "+0 -0" is a line saying nothing. Nothing stands in
    /// its place either: `state` a line below is `WorkspaceStatus.clean`, whose own label already
    /// reads "No changes", and the card drew those two words twice before the picture was looked
    /// at.
    public struct Diff: Sendable, Hashable {
        public var additions: Int
        public var deletions: Int

        public init(additions: Int, deletions: Int) {
            self.additions = additions
            self.deletions = deletions
        }
    }

    /// The pull request this branch has, reduced to what the card draws.
    ///
    /// The URL travels with it even though the card is not clickable, because the card is drawn in
    /// a window that ignores the mouse and the number is therefore a fact rather than a control.
    /// Carrying the address anyway is what keeps this value the answer if the card ever grows a
    /// way to be pressed, and it costs a string.
    public struct PullRequestRef: Sendable, Hashable {
        public var number: Int
        public var title: String
        public var url: String
        public var forge: Forge

        public init(number: Int, title: String, url: String, forge: Forge = .gitHub) {
            self.number = number
            self.title = title
            self.url = url
            self.forge = forge
        }
    }

    /// The workspace's name, whole. The row truncates it; this is the half of the card that
    /// exists because the row truncates it, so nothing here shortens it a second time.
    public var title: String
    /// The branch, whole, slashes and all. Never abbreviated to its last component: two
    /// workspaces on `freek/fix-checks` and `agent/fix-checks` would then draw the same line.
    public var branch: String
    public var diff: Diff?
    /// What the mark in the corner is, in the same vocabulary the row's own mark uses, so the two
    /// cannot say different things about one workspace. See `WorkspaceStatus`.
    public var status: WorkspaceStatus
    /// The state in words, because a glyph on a card nobody can hover has no tooltip to fall back
    /// on. `WorkspaceStatus.label`, so the card, the legend and the filter all read the same.
    public var state: String
    /// The numbers behind the state, such as how many checks failed. Nil when the state's own
    /// words are all there is.
    public var detail: String?
    public var pullRequest: PullRequestRef?
    /// How long since anything happened here, as a phrase. See `HomeAge.phrase`.
    public var age: String

    public init(
        title: String,
        branch: String,
        diff: Diff? = nil,
        status: WorkspaceStatus,
        state: String,
        detail: String? = nil,
        pullRequest: PullRequestRef? = nil,
        age: String
    ) {
        self.title = title
        self.branch = branch
        self.diff = diff
        self.status = status
        self.state = state
        self.detail = detail
        self.pullRequest = pullRequest
        self.age = age
    }

    /// The counts, from `hasDiff` rather than from a rule of its own, so the card holds the same
    /// opinion about an empty worktree that the row's own counts and `WorkspaceStatus` hold.
    ///
    static func counts(for workspace: Workspace) -> Diff? {
        workspace.hasDiff
            ? Diff(additions: workspace.additions, deletions: workspace.deletions)
            : nil
    }

    /// Whatever GitHub last said, whether or not the state beside it came from GitHub. A workspace
    /// whose agent is mid turn still has its pull request, and "#362" under "Agent running" is two
    /// facts rather than two answers: the state is about now, the number is about the branch.
    /// Suppressing it there would mean the number blinked out every time a turn started, which is
    /// the one moment somebody is most likely to want it.
    ///
    /// A pull request belonging to an earlier life of a reused branch name never reaches here:
    /// `PullRequestOwnership` drops it upstream, which is where that rule lives.
    static func reference(to pullRequest: PullRequest?) -> PullRequestRef? {
        pullRequest.map {
            PullRequestRef(number: $0.number, title: $0.title, url: $0.url, forge: $0.forge)
        }
    }
}
