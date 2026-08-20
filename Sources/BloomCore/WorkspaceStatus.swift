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

        if let pullRequest {
            if pullRequest.isMerged { return .merged }
            if pullRequest.isClosed { return .closed }
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
    public var describesPullRequest: Bool {
        switch self {
        case .merged, .closed, .checksFailing, .checksRunning, .checksPassed, .draft,
             .pullRequestOpen:
            true
        default:
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
        let detail = pullRequest.checksSummary
        if !detail.isEmpty, detail != label { text += ": \(detail)" }
        return text
    }
}
