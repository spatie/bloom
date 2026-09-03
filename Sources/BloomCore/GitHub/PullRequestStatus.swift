import Foundation

/// How a pull request should present itself: what the strip says, what colour it carries, and
/// whether the merge button is allowed to do anything.
///
/// The tone is a meaning, not a colour. The view resolves it against the palette, so the same
/// decision drives the inspector strip and anything else that ever shows this state, and so the
/// decision itself can be tested without a window.
public struct PullRequestStatus: Sendable, Hashable {
    public enum Tone: String, Sendable, Hashable, CaseIterable {
        /// Nothing to signal. Drawn as no tint at all rather than as a grey wash.
        case neutral
        case positive
        case negative
        case warning
        /// Landed. The one outcome in this app that is neither good news nor bad, and the one
        /// meaning with a colour of its own rather than a share of the accent.
        ///
        /// It was `accent` until the palette grew `Palette.merged`, and the rename is the point
        /// rather than a tidy up: a tone is a MEANING, and a case named after a colour is the one
        /// kind of name this enum is not allowed to carry. `Palette.merged` says why purple and
        /// why GitHub's violet rather than Tailwind's.
        case merged
    }

    public var tone: Tone
    /// The headline: what state this pull request is in, in as few words as say it.
    ///
    /// The state rather than the title. The title is the workspace's name a few points to the
    /// left of it and is on GitHub besides; the state is the thing that changes, the thing you are
    /// waiting for, and the thing that says whether to press the button.
    public var text: String
    /// The specifics behind the headline, such as how many checks passed. Nil when the headline
    /// is all there is to say. The strip drops it before it drops anything else.
    public var detail: String?
    public var canMerge: Bool
    /// Why not, in a sentence a tooltip can show. Nil when merging is allowed.
    public var blockedReason: String?
    /// What the strip's one prominent button should offer in this state.
    ///
    /// Decided here rather than in the view, and not re-derived from whatever the view happens to
    /// know about the worktree. The first version of this let the button read the local counts
    /// directly, and a branch with both a conflict and uncommitted work drew "Merge conflicts"
    /// over a Commit and push button: the headline came from the precedence and the button came
    /// from somewhere else, so the strip gave two different answers at once. There is one
    /// decision, so there is one place it is made.
    public var remedy: Remedy

    /// What to do about this state, as far as one button can express it.
    public enum Remedy: Sendable, Hashable {
        /// Land it. What every state GitHub reports on its own offers.
        case merge
        /// Get the worktree onto the remote first. Committing is part of it or it is not,
        /// depending on whether anything is uncommitted, and the label follows.
        case commitAndPush
        case push
        /// Bring the base in and resolve the conflict, because merging is the one thing this state
        /// cannot do. The strip used to draw Merge here, beside a red band saying the branch
        /// conflicts, and pressing it asked the agent to run a command GitHub had already refused.
        case fixConflicts
    }

    // A running agent is not one of the reasons in here: everything in this type is what GitHub
    // says about the pull request. Whether the strip's buttons may be pressed while this
    // workspace's agent is mid turn is `BranchActionAvailability`, which answers for the whole
    // band at once and carries the reason a reader is given.

    public init(
        tone: Tone,
        text: String,
        detail: String? = nil,
        canMerge: Bool,
        blockedReason: String? = nil,
        remedy: Remedy = .merge
    ) {
        self.tone = tone
        self.text = text
        self.detail = detail
        self.canMerge = canMerge
        self.blockedReason = blockedReason
        self.remedy = remedy
    }
}

public extension PullRequest {
    var isOpen: Bool { state.caseInsensitiveCompare("OPEN") == .orderedSame }
    var isMerged: Bool { state.caseInsensitiveCompare("MERGED") == .orderedSame }
    var isClosed: Bool { state.caseInsensitiveCompare("CLOSED") == .orderedSame }

    /// GitHub reports this through two fields with different vocabularies, and gh hands back
    /// whichever one the installed version knows about. `DIRTY` is `mergeStateStatus` for the
    /// same thing `mergeable` calls `CONFLICTING`.
    var hasConflicts: Bool {
        guard let mergeable = mergeable?.uppercased() else { return false }
        return mergeable == "CONFLICTING" || mergeable == "DIRTY"
    }

    /// Present tense, because it is the label on a button that has not been pressed yet.
    var reviewLabel: String? {
        guard let reviewDecision, !reviewDecision.isEmpty else { return nil }
        return reviewDecision.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// The state of this pull request, with what the worktree is holding weighed against it.
    ///
    /// GitHub is the authority on everything in `status` and on nothing here. Every state it
    /// reports describes the commit that was pushed: "12 of 12 checks passed" is a fact about a
    /// commit, and the moment anything is edited or committed after that push, the fact is about
    /// something that no longer exists on this machine. "Ready to merge" over a branch whose work
    /// is still on disk is not a slightly stale answer, it is the wrong one, and acting on it
    /// merges a pull request without the change the reader is looking at and deletes the branch.
    ///
    /// The precedence, worst first, and why:
    ///
    /// 1. **Merged** and **closed**. Facts about the pull request itself rather than about a
    ///    commit, and nothing local changes either. Local work on a merged branch belongs to the
    ///    NEXT pull request, so pointing at a push here would be pointing at a dead branch.
    /// 2. **Merge conflicts**. Also outranks local work, and this one is a judgement call rather
    ///    than an obvious ordering. GitHub computed it against the pushed head, so in principle
    ///    the conflict could already be resolved on disk. It stays first because it is the only
    ///    state that a push cannot clear, because it is the one that needs a person, and because
    ///    it is the one where being wrong costs the most.
    /// 3. **Local changes**. Above everything derived from the check and review rollup, because
    ///    every one of those is a claim about a commit the reader does not have. Above draft too:
    ///    draft is a property you set and already know, and local work is news.
    /// 4. Draft, then the rollup: checks failing, checks running, changes requested, waiting for
    ///    review, ready to merge.
    ///
    /// Merging is NOT blocked. The button stays live and the confirmation says what is missing,
    /// because whether uncommitted work belongs to this pull request is a question only the reader
    /// can answer: an agent leaves scratch files in a worktree constantly, and a strip that
    /// disabled the app's most important control over an untracked `notes.md` would be wrong far
    /// more often than it was right. Telling the truth loudly and letting the reader decide is the
    /// trade this makes.
    ///
    /// Local work TAKES the headline; it does not hide one. A state that is already bad news keeps
    /// its own words and gains the local count on the line below, because the sidebar row for the
    /// same workspace is painting an error mark and saying "Checks failing", and a strip that
    /// answered "Local changes" to the same question left one workspace with two verdicts in two
    /// panes. What local work must never leave standing is the state that invites a merge:
    /// "Ready to merge" over work that is still on disk is not a stale answer but a wrong one, and
    /// acting on it merges without the change the reader is looking at. So the swap happens
    /// exactly there, where the headline is positive, and nowhere else.
    func status(local: LocalWork?) -> PullRequestStatus {
        let base = status
        guard let local, local.isAhead, isOpen, !hasConflicts else { return base }

        let remedy: PullRequestStatus.Remedy = local.hasUncommitted ? .commitAndPush : .push
        let localDetail = Self.localDetail(local)

        guard base.tone == .positive else {
            return PullRequestStatus(
                tone: base.tone,
                text: base.text,
                detail: [base.detail, localDetail]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: ", "),
                canMerge: base.canMerge,
                blockedReason: base.blockedReason,
                remedy: remedy
            )
        }

        return PullRequestStatus(
            tone: .warning,
            text: "Local changes",
            detail: localDetail,
            canMerge: base.canMerge,
            blockedReason: base.blockedReason,
            remedy: remedy
        )
    }

    /// What is local, counted rather than named.
    ///
    /// One headline and two possible halves rather than two states, because the two facts have one
    /// remedy in this app: the button hands the work to the agent, and an agent asked to push
    /// uncommitted work commits it first. A state that does not change what the button does does
    /// not need to be its own state. What they do change is the sentence, which is what this is.
    ///
    /// Both halves when both are true, in the order they have to be dealt with: nothing can be
    /// pushed until it is committed.
    static func localDetail(_ local: LocalWork) -> String {
        var parts: [String] = []
        let files = local.modifiedFiles + local.untrackedFiles
        if files > 0 {
            parts.append("\(files) file\(files == 1 ? "" : "s") to commit")
        }
        if local.hasUnpushed {
            let count = local.unpushedCommits
            parts.append("\(count) commit\(count == 1 ? "" : "s") to push")
        }
        return parts.joined(separator: ", ")
    }

    var status: PullRequestStatus {
        if isMerged {
            return PullRequestStatus(
                tone: .merged,
                text: "Merged",
                canMerge: false,
                blockedReason: "This pull request is already merged."
            )
        }
        if isClosed {
            return PullRequestStatus(
                tone: .neutral,
                text: "Closed",
                canMerge: false,
                blockedReason: "This pull request was closed without merging."
            )
        }
        // Conflicts outrank the check rollup: green checks on a branch that cannot be applied to
        // the base is the one combination where the cheerful answer is the wrong one.
        if hasConflicts {
            return PullRequestStatus(
                tone: .negative,
                text: "Merge conflicts",
                detail: "This branch conflicts with the base branch",
                canMerge: false,
                blockedReason: "Resolve the conflicts with the base branch first.",
                // The one state whose remedy is neither merging nor pushing. It is set here and
                // not weighed against local work, because `status(local:)` hands a conflict
                // straight back: a conflicted branch with uncommitted files still needs the
                // conflict resolved first, and resolving it is going to make more local work
                // rather than less.
                remedy: .fixConflicts
            )
        }
        if isDraft {
            return PullRequestStatus(
                tone: .neutral,
                text: "Draft",
                detail: checksDetail,
                canMerge: false,
                blockedReason: "This pull request is still a draft."
            )
        }

        return PullRequestStatus(
            tone: openTone, text: openHeadline, detail: checksDetail, canMerge: true
        )
    }

    /// The title of the confirmation, which is the one line a user reliably reads.
    ///
    /// It says who does it, and that is the whole of the change from the version that read "Merge
    /// #42 into main?". Bloom no longer runs `gh pr merge`: the request goes to this workspace's
    /// agent as an ordinary turn, and a title that implies the app is about to do it is the one
    /// line most likely to be believed.
    func mergeConfirmationTitle(base: String) -> String {
        "Ask the agent to merge #\(number) into \(base)?"
    }

    /// What confirming does, said as consequences rather than as a question.
    ///
    /// Rewritten when the merge moved onto the agent, and the closing paragraph is the part that
    /// changed meaning rather than wording. It used to end "Bloom cannot undo this", which was the
    /// honest thing to say about an app that was about to call `gh pr merge` itself and had no
    /// answer for what came back. Bloom does not call it any more. What the reader is agreeing to
    /// is a message going into the chat, and the two facts that follow from that are worth more
    /// than an undo warning: the commands happen in front of them, under whatever permission mode
    /// they set, and a refusal from GitHub comes back as words instead of as a failed button.
    ///
    /// What did NOT change is the first paragraph. A squash merge still lands what GitHub has,
    /// not what is on this disk, and moving the work to an agent does not put an uncommitted file
    /// into the merge. The strip lets the button stay live over local work rather than disabling
    /// it, so this is still where that trade is paid back.
    ///
    /// The two conditional paragraphs are not compression candidates. Each of them only appears
    /// when it is the most important thing on screen.
    func mergeConfirmation(
        base: String,
        deletesBranch: Bool,
        local: LocalWork? = nil
    ) -> String {
        var paragraphs: [String] = []
        // First, above the rest, because it is the one line here that says the merge will land
        // something OTHER than what the reader is looking at.
        if let local, local.isAhead {
            paragraphs.append(
                "GitHub does not have everything in this worktree: "
                    + Self.localDetail(local)
                    + ". None of that is part of what is merged, and the agent is told to leave it"
                    + " alone rather than commit it first."
            )
        }
        if checks == .failing || hasConflicts {
            paragraphs.append(
                checks == .failing ? checksSummary : "This branch conflicts with \(base)."
            )
        }
        // An older gh does not report the head branch, and naming a branch we are guessing at
        // would be worse than not naming one. The instructions this turn carries say the same
        // thing: without a name, the branch on the server is left standing.
        var closing = "This workspace's agent is asked to merge it, in the chat, so you see every "
            + "command it runs and it can tell you if GitHub refuses."
        if deletesBranch, !branch.isEmpty {
            closing += " Once the merge lands it deletes \(branch) on GitHub, not here."
        }
        paragraphs.append(closing)
        return paragraphs.joined(separator: "\n\n")
    }

    /// The headline for an open, unblocked pull request.
    ///
    /// One thing at a time, worst first. A branch with a failing check and a pending review has
    /// two problems and only the first of them is worth a headline, because it is the one that has
    /// to be fixed before the second one matters.
    private var openHeadline: String {
        switch checks {
        case .failing: return "Checks failing"
        // The headline has to agree with the line under it. `GitHub.rollup` tells a queued check
        // from a running one and says which in the summary, so a headline fixed at "Checks
        // running" would sit over the words "1 check queued". The summary is read back rather
        // than recomputed because `rollup` is its only writer and `PullRequest` carries no
        // rollup nodes to ask again. `WorkspaceStatusTests` pins the two lines together, in both
        // vocabularies, so a change to one of them fails rather than drifting.
        case .pending: return checksSummary.hasSuffix("queued") ? "Checks queued" : "Checks running"
        case .passing, .none: break
        }
        switch reviewDecision?.uppercased() {
        case "CHANGES_REQUESTED": return "Changes requested"
        case "REVIEW_REQUIRED": return "Waiting for review"
        default: return "Ready to merge"
        }
    }

    /// The numbers behind the headline. Nil when GitHub has reported no checks at all, because
    /// "No checks" under "Ready to merge" reads as something missing rather than as a fact.
    private var checksDetail: String? {
        guard checks != .none, !checksSummary.isEmpty else { return nil }
        return checksSummary
    }

    private var openTone: PullRequestStatus.Tone {
        switch checks {
        case .failing: return .negative
        case .pending: return .warning
        case .passing, .none: break
        }
        switch reviewDecision?.uppercased() {
        case "CHANGES_REQUESTED", "REVIEW_REQUIRED": return .warning
        // Nothing failing, nothing pending and nobody blocking it. Teal rather than GitHub's
        // green: the brand ramp says to reuse the accent instead of inventing a green, and this
        // is the state the whole strip is tinted for.
        default: return .positive
        }
    }
}

public extension GitHub.MergeMethod {
    /// GitHub's own words for the three buttons, so the confirmation reads like the web UI the
    /// user will check afterwards.
    var label: String {
        switch self {
        case .merge: "Merge commit"
        case .squash: "Squash and merge"
        case .rebase: "Rebase and merge"
        }
    }
}
