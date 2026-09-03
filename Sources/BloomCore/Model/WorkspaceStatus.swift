import Foundation

/// What a workspace amounts to, in one word, for the mark at the head of its sidebar row.
///
/// This lives in the core rather than in the row because it is a decision, not a drawing: with a
/// dozen workspaces open the mark is the only thing that says which one wants attention, and the
/// order the cases are resolved in is the whole of that judgement. Keeping it here means the
/// judgement can be tested against fixtures instead of being read off a screenshot.
///
/// The order below is the precedence order, most urgent first. Two things can be true at once
/// (an agent running in a workspace whose checks are red), and the row only has room for one.
public enum WorkspaceStatus: String, Sendable, Hashable, CaseIterable, Codable {
    /// The setup script is still running, so nothing here can be trusted yet.
    case settingUp
    /// An agent asked to do something and is holding its turn open until somebody answers.
    ///
    /// Above `running` on purpose, and it is the only state that outranks it. A running agent is
    /// spending time on the user's behalf and needs nothing; this one is spending time and getting
    /// nowhere, and it is the only state in the list that gets worse the longer it is left. The
    /// CLI puts no timer on the question, so nothing resolves it except a person.
    case awaitingPermission
    /// An agent is mid turn right now.
    case running
    /// The setup script failed, so this workspace never became usable.
    case setupFailed
    /// A turn finished and nobody has read what it said.
    case unread
    /// The pull request is in. This workspace is finished and can be archived.
    case merged
    /// The pull request was closed without merging.
    case closed
    /// The branch cannot be applied to its base, so nothing merges until a person resolves it.
    ///
    /// Above the check rollup and above `draft`, which is where `PullRequest.status` already puts
    /// it. Without a case of its own a conflicted branch fell through to whatever CI last said, so
    /// the pull request band drew "Merge conflicts" in red while the sidebar row beside it drew a
    /// green tick: one workspace, two verdicts, in two panes an inch apart. A conflict is also the
    /// only state in this block that a push cannot clear.
    case conflicted
    /// CI has rejected the branch.
    case checksFailing
    /// CI has not finished with the branch.
    case checksRunning
    /// CI is happy. This is the state a review can start from.
    case checksPassed
    /// A pull request exists but is explicitly not ready to be looked at.
    case draft
    /// A pull request exists and GitHub has nothing to say about it yet.
    case pullRequestOpen
    /// Work in the worktree, committed or not, and no pull request for it.
    case changed
    /// A worktree that matches its base branch. Nothing has happened here.
    case clean

    /// Resolved once, so the row, its tooltip and VoiceOver cannot disagree about what it is.
    ///
    /// `isRunning` is passed in because only the app layer knows whether an agent has a turn open,
    /// and `pullRequest` is optional because gh may be missing, signed out, or simply not asked
    /// yet. A missing pull request is never reported as a bad one: the workspace falls back to
    /// what git alone can say.
    ///
    /// `isAwaitingPermission` is passed in for the same reason `isRunning` is: only the app layer
    /// knows which agents are blocked, and it defaults to false so no existing caller changes
    /// meaning by not knowing about it.
    public static func resolve(
        workspace: Workspace,
        isRunning: Bool,
        pullRequest: PullRequest?,
        isAwaitingPermission: Bool = false
    ) -> WorkspaceStatus {
        if workspace.setupState == .running { return .settingUp }
        // Ahead of `running`, because a blocked workspace looking the same as a working one is the
        // failure this state exists to prevent.
        if isAwaitingPermission { return .awaitingPermission }
        if isRunning { return .running }
        if workspace.setupState == .failed { return .setupFailed }
        if workspace.unread { return .unread }

        return ofBranch(workspace: workspace, pullRequest: pullRequest)
    }

    /// The same verdict with the agent left out of it: what is true of the BRANCH and whatever
    /// pull request it has.
    ///
    /// The tail of `resolve`, named rather than copied, because the card that opens over the pull
    /// request band needs exactly this half. That band is about a branch, so a mark reading
    /// "Agent running" or "Unread" over it would be answering a question nobody asked there, and
    /// a second copy of the precedence below is how two panes come to disagree about one
    /// workspace. See `WorkspaceHoverCard.pullRequestBand`.
    public static func ofBranch(
        workspace: Workspace,
        pullRequest: PullRequest?
    ) -> WorkspaceStatus {
        if let pullRequest {
            if pullRequest.isMerged { return .merged }
            if pullRequest.isClosed { return .closed }
            // Before the draft flag and before the rollup, in `PullRequest.status`'s order rather
            // than in one invented here. Green checks on a branch that cannot be applied to the
            // base is the combination where the cheerful answer is the wrong one, and a draft that
            // also conflicts still conflicts.
            if pullRequest.hasConflicts { return .conflicted }
            if pullRequest.isDraft { return .draft }
            switch pullRequest.checks {
            case .failing: return .checksFailing
            case .pending: return .checksRunning
            case .passing: return .checksPassed
            case .none: return .pullRequestOpen
            }
        }

        return workspace.hasDiff ? .changed : .clean
    }

    /// The short form, for a legend or a filter.
    public var label: String {
        switch self {
        case .settingUp: "Setting up"
        case .awaitingPermission: "Waiting on you"
        case .running: "Agent running"
        case .setupFailed: "Setup failed"
        case .unread: "Unread"
        case .merged: "Merged"
        case .closed: "Pull request closed"
        // The band's own words, so the row and the strip name one thing one way.
        case .conflicted: "Merge conflicts"
        case .checksFailing: "Checks failing"
        case .checksRunning: "Checks running"
        case .checksPassed: "Checks passed"
        case .draft: "Draft pull request"
        case .pullRequestOpen: "Pull request open"
        case .changed: "Has changes"
        case .clean: "No changes"
        }
    }

    /// Whether this verdict came from GitHub rather than from the worktree.
    ///
    /// **Both halves are written out, and the `default` that used to stand for the second one is
    /// the reason.** This is what decides whether `summary` and `detail` reach for a pull request
    /// at all, so a state added to the GitHub block above and not added here is a state whose
    /// tooltip silently loses the number the reader is hovering for. With a `default` the compiler
    /// had nothing to say about that; listing the worktree states makes a new case a build error
    /// in the one place that has to be told about it. `conflicted` was added to this enum after
    /// the rest and is exactly the shape of case that would have been missed.
    public var describesPullRequest: Bool {
        switch self {
        case .merged, .closed, .conflicted, .checksFailing, .checksRunning, .checksPassed, .draft,
             .pullRequestOpen:
            true
        case .settingUp, .awaitingPermission, .running, .setupFailed, .unread, .changed, .clean:
            false
        }
    }

    /// Whether this workspace is stopped until a person does something about it. The one state
    /// where the passage of time is pure waste.
    public var needsAnswer: Bool { self == .awaitingPermission }

    /// The sentence the tooltip and VoiceOver get.
    ///
    /// A colour and a glyph cannot say "1 required check failed", and that number is the reason
    /// the user is hovering the mark in the first place, so the pull request's own summary is
    /// carried through rather than reduced to the state's name.
    public func summary(pullRequest: PullRequest?) -> String {
        if self == .awaitingPermission {
            return "The agent is asking for permission and cannot go on until you answer."
        }
        guard describesPullRequest, let pullRequest else { return label }

        var text = "\(label), pull request #\(pullRequest.number)"
        if let detail = detail(pullRequest: pullRequest) { text += ": \(detail)" }
        return text
    }

    /// The numbers behind the state's name, or nil when the name is all there is to say.
    ///
    /// Split out of `summary` rather than copied from it, for `WorkspaceHoverCard`, which draws
    /// the state and its detail as two pieces of text of different weights and so cannot use the
    /// one sentence. The check that the detail is not simply the label again is the part worth
    /// having in one place: gh reports "Checks failing" as its own rollup summary often enough
    /// that a card built on a copy of this would have said it twice.
    public func detail(pullRequest: PullRequest?) -> String? {
        guard describesPullRequest, let pullRequest else { return nil }
        // The rollup is not what is wrong with a conflicted branch, and "Merge conflicts: 12 of 12
        // checks passed" is a tooltip arguing with its own headline. The band's sentence instead,
        // read off the band rather than copied from it, so the two cannot drift.
        if self == .conflicted { return pullRequest.status.detail }
        let detail = pullRequest.checksSummary
        guard !detail.isEmpty, detail != label else { return nil }
        return detail
    }
}
