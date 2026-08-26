import SwiftUI
import AppKit
import BloomCore

/// The strip when a pull request already exists: which one it is, what state it is in, and the one
/// button that finishes the job.
///
/// Reading left to right it is the same order as the question a user is asking: which pull
/// request is this, where do I read it, what is going on with it, and can I land it.
///
/// The headline is the STATE and not the title. The title is the workspace's name a few points to
/// the left and is on GitHub besides, while the state is the thing that changes, the thing you are
/// waiting for and the thing that says whether to press the button. It used to be the other way
/// round, with the state reduced to a grey capsule at the trailing edge, and the strip read as a
/// caption for something rather than as the top of the column.
///
/// The badge, the headline and the merge button all take the state's colour, and `PullRequestBar`
/// washes the bar behind them with it, because a red bar at the top of the inspector is visible
/// from across the room and a red word is not.
struct PullRequestSummary: View {
    var pullRequest: PullRequest
    var baseBranch: String
    /// Where the login runs if it turns out GitHub is not connected. See `propose`.
    var worktree: String
    /// What this worktree is holding that GitHub has not got. Nil while the first refresh is
    /// still running, which is not the same as "nothing", and is drawn as nothing extra.
    var localWork: LocalWork?
    var isWorking: Bool
    /// Whether this strip may act on the branch at all, decided once for the whole band.
    ///
    /// Every button here works by composing a turn and sending it, and what the agent then does
    /// is commit, push, merge, cut a branch or bring the base in. While a turn is already running
    /// none of that may start: see `BranchActionAvailability`, which holds the reason and the
    /// words. `PullRequestCreator` takes the same value for the same reason.
    var branchActions: BranchActionAvailability
    /// How this project merges, which the split button promises and its menu ticks. Per project
    /// and remembered: see `MergeMethodChoice`.
    var mergeMethod: GitHub.MergeMethod
    /// Changes the method in force. It never merges, which is the whole difference between this
    /// and `onMerge`.
    var onChooseMergeMethod: (GitHub.MergeMethod) -> Void
    var onMerge: (GitHub.MergeMethod) -> Void
    /// Hands the outstanding work to the workspace's agent to commit and push.
    var onPush: () -> Void
    /// Asks the workspace's agent to bring the base branch in and resolve the conflicts with it.
    var onFixConflicts: () -> Void
    /// Carries a merged workspace on to a fresh branch, in place. See `continueButton`.
    var onContinue: () -> Void
    /// Archives, through the app's ordinary archive with all its checks intact.
    var onArchive: () -> Void

    /// Which method the user picked, held only for as long as the confirmation is up. Non-nil is
    /// what presents the dialog, so there is no way to reach `onMerge` without passing through it.
    @State private var pendingMerge: GitHub.MergeMethod?

    /// The merge instructions ask for the branch to be deleted on GitHub, and for nothing on this
    /// machine to be touched. It is named in the confirmation rather than left as a surprise. See
    /// `MergeInstructions.defaultMarkdown`, which is what the agent actually follows, and which is
    /// where the reason gh's own `--delete-branch` is never used is written down.
    private static let deletesBranch = true

    private var status: PullRequestStatus { pullRequest.status(local: localWork) }

    /// Whether this strip is asking for something or reporting something.
    ///
    /// Open is a request: there is a button in the band and a state you are waiting on. Merged and
    /// closed are answers, and they are drawn a rung quieter for it. The same question decides the
    /// band's own wash, in `PullRequestBar`.
    private var isPending: Bool { pullRequest.isOpen }

    var body: some View {
        HStack(spacing: InspectorLayout.gap) {
            identity
            headline
            trailing
        }
        // Sharing lives here rather than as another control in the strip. The strip has one length
        // that can give way and it is already the headline, so a button added to it comes out of
        // the part the reader is trying to read. A right click costs no width at all, and it is
        // where a link is asked for everywhere else on this system.
        .contextMenu {
            Button("Open on GitHub") { GitHubBridge.open(pullRequest.url) }
            Button("Copy link", action: copyLink)
            if let url = URL(string: pullRequest.url) {
                // A submenu of this menu rather than a picker that replaces it, which is where
                // Finder puts Share.
                ShareLink(item: url) { Text("Share") }
            }
        }
        // Attached to the merge button's own row, so the dialog animates out of the control that
        // asked for it.
        //
        // Bloom's own confirmation and not `.confirmationDialog`, and the reasoning is written
        // out on `ConfirmationSheet`. The short version is that this is the one confirmation in
        // the app whose answer is not a loss, a system dialog can only draw its confirm button in
        // red or grey, and the roles that draw it grey are the same roles that hand the merge to
        // the Return key. `a595dfb` measured that and kept the red button rather than give up the
        // guard. This keeps the guard and drops the red: Escape still cancels, Return still does
        // nothing, and the button that lands the branch is finally the colour of landing it.
        .confirmation($pendingMerge) { method in
            Confirmation(
                title: pullRequest.mergeConfirmationTitle(base: baseBranch),
                // The two things that change the answer, and nothing else. The title above names
                // the pull request and the button below names the method, so neither is repeated.
                message: pullRequest.mergeConfirmation(
                    base: baseBranch,
                    deletesBranch: Self.deletesBranch,
                    local: localWork
                ),
                confirmLabel: method.label,
                // Escape lands here. See `ConfirmationSheet` for why no confirmation in this app
                // gives its cancel button `.keyboardShortcut(.defaultAction)`.
                cancelLabel: "Keep the pull request open",
                tone: .completing
            )
        } onConfirm: { method in
            onMerge(method)
        }
        // The Workspace menu's copy of the merge, which had no item anywhere until now. It is
        // published from here because here is the only place that can raise the confirmation
        // above, so the menu item asks this view rather than growing a second path to a merge.
        // See `MergeAction`.
        .focusedSceneValue(\.mergeAction, mergeAction)
    }

    /// What the menu bar's Merge item says and does, or nil when this strip has nothing to land:
    /// a pull request that is closed or already merged has no merge to offer, and neither has one
    /// whose band is mid request.
    private var mergeAction: MergeAction? {
        guard pullRequest.isOpen, !isWorking else { return nil }
        return MergeAction(
            title: mergeMethod.buttonLabel,
            // The same two answers the button reads, in the same order: the cluster's, which is
            // whether a turn may start at all, and then GitHub's.
            isEnabled: branchActions.isAllowed && status.canMerge,
            perform: { propose(mergeMethod) }
        )
    }

    // MARK: - Parts

    /// The number, the way out to the browser, and whether this is still a draft.
    ///
    /// The number and the arrow are one control rather than two: see `PullRequestBadge` for why,
    /// and for where the numbers in it came from. Draft stays a chip of its own beside it, since
    /// it says something about the pull request rather than being a way of reaching it.
    private var identity: some View {
        HStack(spacing: InspectorLayout.tight) {
            PullRequestBadge(
                number: pullRequest.number,
                title: pullRequest.title,
                url: pullRequest.url,
                tint: tint
            )
            if pullRequest.isDraft { draftChip }
        }
        .fixedSize()
    }

    /// Draft, said beside the number rather than in the headline.
    ///
    /// The headline is a precedence: one thing at a time, worst first. Draft sits low in it, so a
    /// draft that also conflicts, or that has a failing check, drew "Merge conflicts" and said
    /// nothing about being a draft at all. Draftness is not a state that competes with those; it
    /// is a property of the pull request that stays true underneath whatever else is wrong, and
    /// it changes what the reader expects of the whole strip. So it lives with the number, which
    /// is the other thing about this pull request that is simply true.
    private var draftChip: some View {
        Chip(text: "Draft", tint: Palette.textSecondary, background: Palette.hover)
            .help("This pull request is still a draft, so it cannot be merged.")
            .accessibilityLabel("Draft")
    }

    /// The state, in the state's colour, with its numbers under it.
    ///
    /// A flexible frame rather than a `Spacer` and a negative layout priority: this is the one
    /// thing in the strip that can be any length, so it takes whatever width is left and truncates
    /// inside it, which is a rule the layout cannot resolve any other way.
    ///
    /// Two rungs, not one, because the two kinds of state are not the same kind of sentence.
    ///
    /// A pull request that is still open is asking for something, and it is the top of this
    /// column: `Typo.heading`, 15 points, the only rung above reading size. It was
    /// `Typo.captionEmphasis`, 11 points, which is two points SMALLER than the file names in the
    /// list underneath. A heading that is smaller than the rows it heads is not a heading, and
    /// no amount of colour fixes that; it is the whole of the "still small font" complaint.
    ///
    /// Merged and closed are reports of something already finished. They drop to `Typo.title`,
    /// which is the system's own heading style at reading size, so they still read as a heading
    /// and stop competing with the diff. Flattening the two to one treatment is how a strip ends
    /// up either shouting about a merged branch or whispering about one that is ready to land.
    private var headline: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingHair) {
            Text(status.text)
                .font(isPending ? Typo.heading : Typo.title)
                .foregroundStyle(tint ?? Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            if let detail = detailLine {
                Text(detail)
                    .font(Typo.caption)
                    // Grey, and deliberately so: it is a count read off the headline above it, and
                    // a second coloured line would leave the strip with nothing quiet in it. What
                    // it is NOT any more is `textTertiary`, which is the palette's faded rung at
                    // 2.9 to 1 on white. A number nobody can read is not a quiet number, it is a
                    // missing one, and two faded rungs stacked is most of what "ugly grey" meant.
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// The one line under the headline, and what takes it over while the agent is working.
    ///
    /// A band that is holding its buttons back says so here rather than only in a tooltip.
    /// "1 check passed" is a fact that will still be true in a minute, and a reader looking at
    /// four greyed out controls is asking a different question. Nobody hovers a disabled control
    /// to find out why it is disabled unless they already suspect the answer.
    private var detailLine: String? {
        branchActions.note ?? status.detail
    }

    /// The one prominent control, whichever it is, and whatever stands beside it.
    ///
    /// The primary slot belongs to whatever the state is actually asking for. With local work in
    /// the worktree that is not Merge: merging now would land the pull request WITHOUT what the
    /// reader is looking at and delete the branch it was on. So the primary swaps to Commit and
    /// push, and merging stays exactly one press away in the quiet split button beside it, which
    /// carries the same method and opens the same confirmation. Nothing is taken away; what
    /// changes is which of the two the strip is pointing at.
    ///
    /// **The primary control is last in every one of these, and that is the whole rule.** It used
    /// to be first, with the merge method chevron or Archive after it, so the button the strip
    /// exists for landed at a different distance from the pane's edge in every state: measured at
    /// the pane's default width, Merge ended 21 points short of the inset, Continue 96 points
    /// short, and Create pull request flush against it. A control that moves half an inch as a
    /// workspace changes state is a control you have to look for. Now the leading content is the
    /// only thing that gives way, and the primary's trailing edge is the pane's own inset in
    /// every state the strip can be in.
    ///
    /// Everything that is not the primary sits immediately before it, at the tight spacing, so
    /// the pair still reads as one cluster rather than as two controls that happen to be near
    /// each other. The merge method chevron used to be the awkward one here: it stood BEFORE
    /// Merge, on the leading side, because a 19 point chevron at the trailing edge is exactly the
    /// misalignment the rule above was written to fix. It is inside the button now, on the
    /// trailing side where a split button carries it, and the button's own trailing edge is still
    /// the pane's inset. See `mergeControl`.
    private var trailing: some View {
        // Disabled here, for the cluster, rather than on each button in it. Everything in this
        // slot ends in a turn that writes to the worktree or the branch, so it is one question,
        // and a control added to the cluster later inherits the answer instead of having to
        // remember to ask it. `BranchActionAvailability` carries what is held back and why.
        // Nothing outside this slot is touched: the number, the arrow out to the browser and the
        // strip's own context menu only ever read.
        trailingControls
            .disabled(!branchActions.isAllowed)
    }

    @ViewBuilder
    private var trailingControls: some View {
        if isWorking {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Working")
        } else if pullRequest.isOpen {
            HStack(spacing: Metrics.spacingTight) {
                // Only when merging is not what the state is asking for, because then the split
                // button IS the primary and there is nothing to stand beside it. This is what the
                // old chevron did in those states: it was the only way to merge a branch whose
                // primary said Commit and push, and losing it would have taken a route away.
                if status.remedy != .merge { mergeControl(isPrimary: false) }
                primaryButton
            }
            .fixedSize()
        } else if pullRequest.isMerged {
            HStack(spacing: Metrics.spacingTight) {
                continueButton
                archiveButton
            }
            .fixedSize()
        }
        // A CLOSED pull request still gets nothing, and that is not an oversight. Continue is
        // built on the merge: the work is on the base branch, so cutting a fresh branch from the
        // base loses none of it. A closed pull request landed nothing, its branch is still the
        // only place its commits live, and moving off it would be exactly the wrong offer. Archive
        // on its own would be a control that says "throw this away" over a branch nobody has
        // agreed to throw away.
    }

    /// Which of the three the open state's primary slot holds.
    ///
    /// A switch rather than a chain of conditions, and the reason is the failure this project has
    /// had four times: the remedy is an enum in the core, and a case added to it has to stop
    /// compiling here rather than quietly falling through to whichever branch happened to be last.
    /// The decision itself is `PullRequest.status(local:)`, tested, because a decision taken in a
    /// view is a decision nothing can test.
    @ViewBuilder
    private var primaryButton: some View {
        switch status.remedy {
        case .merge: mergeControl(isPrimary: true)
        case .fixConflicts: fixConflictsButton
        case .commitAndPush, .push: pushButton
        }
    }

    /// Carry this workspace on, on a new branch, without giving up the session.
    ///
    /// A merged workspace used to be a dead end: the branch is finished, the strip goes quiet and
    /// the only move left is to archive and start again. Starting again is not free. The worktree
    /// has its dependencies installed, its `.env` copied in and its dev servers on their ports,
    /// and the agent's session has read this codebase and been corrected about it for an hour.
    /// None of that is in git and all of it is thrown away by an archive. Continuing keeps every
    /// bit of it and replaces only the part that is genuinely over, which is the branch.
    ///
    /// Outlined, and first in the pair. `b0cdf0f` had it the other way round and filled this one,
    /// on the argument that the filled control marks what is RECOMMENDED rather than what is
    /// likely, and that nothing is recommended less than the irreversible button beside it. That
    /// argument is sound about confirmations and wrong about this strip, and the owner has
    /// overruled it: a merged pull request is a finished workspace, archiving is what almost every
    /// one of them is for, and a strip whose prominent control is the rare answer points the
    /// reader away from the thing they came to do. The guard against pressing Archive by accident
    /// is not its emphasis, it is `AppModel.archive`, which still builds the full safety report and
    /// still stops to ask whenever there is genuinely something to lose. See `archiveButton`.
    ///
    /// So the pair keeps both buttons at full size, one click apart, and swaps which of them is
    /// filled. It also swaps their order, because the rule from `e9ef824` is that the primary
    /// control's trailing edge is the pane's own inset in EVERY state: a primary that moves half
    /// an inch as a workspace changes state is a primary you have to look for. Archive is primary
    /// here, so Archive is last.
    ///
    /// The two forms are the same trick `pushButton` uses. "Continue" beside "Archive" and a
    /// headline is more than the pane's default width carries, and the headline is the part that
    /// must not be the thing that truncates.
    private var continueButton: some View {
        ViewThatFits(in: .horizontal) {
            continueControl.labelStyle(.titleAndIcon)
            continueControl.labelStyle(.iconOnly)
        }
        .fixedSize()
    }

    private var continueControl: some View {
        Button("Continue", systemImage: "chevron.forward.2", action: onContinue)
            .buttonStyle(.bordered)
            .tint(tint ?? Palette.accent)
            .controlSize(.regular)
            .help(
                branchActions.reason
                    ?? "Cut a new branch from \(baseBranch) in this worktree and carry on, "
                        + "keeping this workspace's session, its setup and anything uncommitted."
            )
    }

    /// Archive, filled, and without a confirmation of its own.
    ///
    /// The prominent control on a landed pull request, which is a reversal of `b0cdf0f` and is
    /// argued out on `continueButton`. It is last in the pair for the same reason every other
    /// state's primary is last: `e9ef824` pinned the primary's trailing edge to the pane's inset,
    /// and that rule does not get an exception for the one state whose primary is a removal.
    ///
    /// **This deliberately differs from the sidebar row's hover archive button, which asks every
    /// single time.** They are not in disagreement; they are different presses. The row's button
    /// appears under the pointer unbidden, a few points from the row you meant to click, so the
    /// asking is a property of that entry point rather than of archiving (the reasoning is
    /// written out in full at `SidebarWorkspaceRow.confirmRowArchive`). This one is a deliberate
    /// press on a strip whose headline says Merged, in a pane the reader opened to look at the
    /// work that landed. A confirmation here would be asking "are you sure?" about a branch
    /// GitHub has already merged, which is how confirmations stop being read.
    ///
    /// Quiet is not the same as unguarded. This goes through `AppModel.archive` exactly as every
    /// other entry point does, and that method still builds the full `WorkspaceSafetyReport` and
    /// still stops to ask when there is genuinely something to lose: an agent mid turn, files git
    /// has never seen, an edited `.env`, commits made on a detached HEAD. What the merge changes
    /// is only the commits, and only through `isPullRequestMerged`, which is true here because
    /// GitHub said so. Nothing about the safety checks is weakened to make this button quiet.
    private var archiveButton: some View {
        ViewThatFits(in: .horizontal) {
            archiveControl.labelStyle(.titleAndIcon)
            archiveControl.labelStyle(.iconOnly)
        }
        .fixedSize()
    }

    private var archiveControl: some View {
        Button("Archive", systemImage: "archivebox", action: onArchive)
            .buttonStyle(.borderedProminent)
            .tint(status.tone.fill)
            .controlSize(.regular)
            .help(
                branchActions.reason
                    ?? "Remove this workspace's worktree. #\(pullRequest.number) is merged, so "
                        + "this asks first only when something here exists nowhere else."
            )
    }

    /// Commit what is outstanding and push it, by asking the agent to.
    ///
    /// Bloom never writes the commit message. The agent knows what it changed and how this project
    /// words a commit; Bloom knows only that a file is dirty, and a message invented from that
    /// would be in the history forever. Same route as Create pull request: it composes a turn and
    /// sends it, so the request lands in the transcript where it can be read and corrected.
    ///
    /// The label follows the fact rather than being one word for both halves. "Commit and push"
    /// over a worktree with nothing to commit is a small lie, and the reader is standing right in
    /// front of the thing it would be lying about.
    /// Two forms, the way `PullRequestCreator` gives its own button two. "Commit and push" is the
    /// longest label anything in this strip carries, and beside a 15 point headline, a chip and a
    /// menu it does not fit the pane at its default width. Dropping the title rather than letting
    /// the headline truncate keeps the sentence, which is the part that cannot be guessed from a
    /// glyph.
    private var pushButton: some View {
        ViewThatFits(in: .horizontal) {
            pushControl.labelStyle(.titleAndIcon)
            pushControl.labelStyle(.iconOnly)
        }
        .fixedSize()
    }

    private var pushControl: some View {
        Button(pushLabel, systemImage: "arrow.up.circle", action: onPush)
            .buttonStyle(.borderedProminent)
            .tint(status.tone.fill)
            .controlSize(.regular)
            // Disabled with the rest of the cluster while a turn runs: pushing a worktree that
            // is being written to as it is read publishes half of something.
            .help(
                branchActions.reason
                    ?? "Ask this workspace's agent to \(pushLabel.lowercased()) branch "
                        + "\(pullRequest.branch.isEmpty ? "this branch" : pullRequest.branch), so "
                        + "#\(pullRequest.number) is what is on this disk."
            )
    }

    private var pushLabel: String {
        status.remedy == .push ? "Push" : "Commit and push"
    }

    /// What stands where Merge stands, when merging is the one thing this state cannot do.
    ///
    /// GitHub has already said the branch does not apply to its base, so the Merge button that
    /// used to sit here beside a red band could only ever produce a refusal read back out of `gh`.
    /// The state has one remedy and this offers it: the same route as every other button in the
    /// strip, a turn composed and sent to this workspace's agent, in the transcript, under the
    /// permission mode the reader already set.
    ///
    /// **No confirmation, and that is a decision rather than an oversight.** Merge asks because it
    /// is the one destructive, off-machine thing this app offers: it lands commits on somebody
    /// else's branch and deletes a branch on the server, and none of that can be taken back from
    /// here. This lands nothing anywhere. It brings the base into a worktree that is already the
    /// disposable copy, commits the resolution locally, and is told to push nothing and merge
    /// nothing, so what it can cost is a git operation in a worktree that exists to be thrown
    /// away. Asking "are you sure?" about that is how confirmations stop being read, which is the
    /// same argument `archiveButton` makes for the press above it.
    ///
    /// The sign in gate is skipped for the same reason: nothing in this turn talks to GitHub, so
    /// a signed out `gh` has no bearing on whether it can work.
    ///
    /// Two forms, the way `pushButton` has two. "Fix merge conflicts" is longer than any other
    /// label in the strip and the headline is the part that must not be what truncates.
    private var fixConflictsButton: some View {
        ViewThatFits(in: .horizontal) {
            fixConflictsControl.labelStyle(.titleAndIcon)
            fixConflictsControl.labelStyle(.iconOnly)
        }
        .fixedSize()
    }

    /// Tinted `status.tone.fill`, which in this state is red, and deliberately so.
    ///
    /// Red is the band's colour here and the rule the strip is built on is that the prominent
    /// button carries the colour of the band it stands in: see `PullRequestStatus.Tone.fill`,
    /// where that rule and the reason it is stated once are written out. It reads as the state
    /// rather than as a warning about the press, which is what it already means over Checks
    /// failing, where the same red button lands a branch on somebody's main.
    ///
    /// Tinted explicitly, like every prominent button in this app, because an untinted
    /// `.borderedProminent` follows the system accent and comes out as whatever colour the Mac is
    /// set to. `mergeButton` carries the measurement.
    private var fixConflictsControl: some View {
        Button("Fix merge conflicts", systemImage: "wrench.and.screwdriver", action: onFixConflicts)
            .buttonStyle(.borderedProminent)
            .tint(status.tone.fill)
            .controlSize(.regular)
            // Disabled with the rest of the cluster while a turn runs: merging the base into a
            // worktree an agent is editing is the same collision as the button above it.
            .help(
                branchActions.reason
                    ?? "Ask this workspace's agent to bring \(baseBranch) into this worktree and "
                        + "resolve the conflicts here. Nothing is pushed and #\(pullRequest.number)"
                        + " is not merged."
            )
    }

    /// Merge, and the chevron that chooses which merge, as one control.
    ///
    /// This replaces a pair: a prominent `Merge` button that always proposed a squash, and a small
    /// borderless chevron beside it whose three items each merged by their own method. Nothing has
    /// been dropped. All three methods are still there, still in GitHub's own wording, still one
    /// press from a merge; what changed is that picking one now sets the mode and the button says
    /// which, so the press that lands somebody's branch is always the press on the thing labelled
    /// with what it will do.
    ///
    /// Prominent when merging is what the state is asking for, quiet when it is not. The quiet
    /// form is the old chevron's other job: with local work in the worktree the primary swaps to
    /// Commit and push, and merging has to stay reachable rather than disappear.
    ///
    /// **The tint measurement that used to live here has moved to `MergeSplitButton`,** because
    /// it is the reason that control is drawn the way it is. The short version is unchanged: the
    /// system will not tint a menu, prominent or otherwise, so the band's colour is painted behind
    /// it. What no drawing survives is the window losing key, when AppKit draws every prominent
    /// control as a neutral glass capsule. That is the platform being consistent rather than a bug
    /// here, and it is worth knowing before reading a screenshot of this strip: a grey Merge
    /// button means the screenshot was taken with another app in front.
    ///
    /// Every path through it opens the confirmation. Nothing here performs a merge, and since
    /// merging moved onto the agent nothing anywhere in this target does either.
    private func mergeControl(isPrimary: Bool) -> some View {
        MergeSplitButton(
            method: mergeMethod,
            fill: status.tone.fill,
            isPrimary: isPrimary,
            // Only what GitHub says about the pull request. A running agent is the cluster's
            // answer rather than this control's: see `trailing`.
            canMerge: status.canMerge,
            help: blockedReason,
            choose: onChooseMergeMethod,
            merge: { propose(mergeMethod) }
        )
    }

    // MARK: - Text

    /// What the Merge button has to say for itself, or nil when there is nothing.
    ///
    /// The running agent comes first. It is true of every button in this strip rather than of one
    /// of them, and it is the reason that goes away on its own, so a reader hovering while their
    /// agent is working is told what they are waiting for rather than told about a draft.
    private var blockedReason: String? {
        branchActions.reason ?? status.blockedReason
    }

    /// The title belongs somewhere, and a tooltip on the state is where: it answers "which pull
    /// request is this" without spending any of the strip's width on an answer the reader already
    /// has from the workspace name.
    private var helpText: String {
        var text = "#\(pullRequest.number) \(pullRequest.title)"
        if let detail = status.detail { text += "\n\(detail)" }
        if let reason = status.blockedReason { text += "\n\(reason)" }
        return text
    }

    private var accessibilityText: String {
        [status.text, status.detail].compactMap { $0 }.joined(separator: ", ")
    }

    // MARK: - Actions

    /// The sign in gate stays, even though this app no longer runs `gh` itself. The agent does,
    /// with the same credentials on the same machine, so a signed out user gets the same failure
    /// one turn later and with a wasted turn in front of it. Catching it here is the cheaper half
    /// of the same answer. Opening the page, copying the link and sharing it are ordinary URL
    /// handling and work signed out.
    ///
    /// What is handed to the gate is "open the confirmation", never "merge". A sign in that
    /// succeeds re-raises the dialog the user was heading for and they still have to say yes to
    /// it, which is what makes running it for them safe.
    private func propose(_ method: GitHub.MergeMethod) {
        GitHubSignIn.shared.run(directory: worktree) { pendingMerge = method }
    }

    private func copyLink() {
        Clipboard.copy(pullRequest.url)
    }

    // MARK: - Tint

    /// The same colour `PullRequestBar` washes the strip with, so the parts and the bar under
    /// them cannot drift apart.
    private var tint: Color? {
        status.tone.color
    }
}
