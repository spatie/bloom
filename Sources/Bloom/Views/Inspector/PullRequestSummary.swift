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
/// The chip, the headline and the merge button all take the state's colour, and `PullRequestBar`
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
    var onMerge: (GitHub.MergeMethod) -> Void
    /// Hands the outstanding work to the workspace's agent to commit and push.
    var onPush: () -> Void

    /// Which method the user picked, held only for as long as the confirmation is up. Non-nil is
    /// what presents the dialog, so there is no way to reach `onMerge` without passing through it.
    @State private var pendingMerge: GitHub.MergeMethod?

    /// Merging deletes the branch on GitHub and nothing on this machine. It is named in the
    /// confirmation rather than left as a surprise. See `GitHub.merge` for why the local half of
    /// gh's own clean up is never asked for.
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
        .confirmationDialog(
            pullRequest.mergeConfirmationTitle(base: baseBranch),
            isPresented: $pendingMerge.isPresent(),
            titleVisibility: .visible,
            presenting: pendingMerge
        ) { method in
            Button(method.label, role: .destructive) { onMerge(method) }
            Button("Keep the pull request open", role: .cancel) { pendingMerge = nil }
                .keyboardShortcut(.defaultAction)
        } message: { method in
            // Naming the pull request, the branch and the base, rather than asking "are you
            // sure?". Nothing in Bloom can put any of it back afterwards.
            Text(
                pullRequest.mergeConfirmation(
                    method: method,
                    base: baseBranch,
                    deletesBranch: Self.deletesBranch,
                    local: localWork
                )
            )
        }
    }

    // MARK: - Parts

    /// The number and the way out to the browser, drawn as one cluster. They are the same subject,
    /// so they sit a tight gap apart rather than at the strip's own spacing.
    private var identity: some View {
        HStack(spacing: InspectorLayout.tight) {
            numberChip
            openButton
        }
        .fixedSize()
    }

    private var numberChip: some View {
        // The number alone. A pull request glyph here repeats what the arrow button beside it and
        // the whole column around it already say, and the chip is meant to be read at a glance as
        // an identifier rather than parsed as a badge.
        Chip(
            text: "#\(pullRequest.number)",
            tint: tint ?? Palette.accent,
            background: chipBackground
        )
        .help(pullRequest.title)
        .accessibilityLabel("Pull request \(pullRequest.number), \(pullRequest.title)")
    }

    /// What the number is drawn on, which depends on whether the band under it is coloured.
    ///
    /// On a washed band it is the pane's own colour, not a second wash of the state's. The bar
    /// already carries the tint, so a chip filled with more of the same tint is one hue at two
    /// strengths a millimetre apart: measured on the warning band it came out brown ink on beige,
    /// which was the muddiest thing the strip drew. On the surface colour the chip lifts off the
    /// band instead, and the number stays what it is, an identifier rather than a state.
    ///
    /// On a band with no wash there is nothing to lift off: a surface coloured chip on the surface
    /// is no chip at all, which is exactly what Draft and Closed came out as when this was one
    /// value. Those two keep the accent wash they always had.
    private var chipBackground: Color {
        tint == nil
            ? Palette.accent.opacity(InspectorLayout.tintOpacityStrong)
            : Palette.surface
    }

    /// A separate control rather than making the chip itself clickable: the chip is the label of
    /// the strip, and a label that silently launches a browser is the kind of thing people learn
    /// by accident.
    ///
    /// Opening a page in a browser needs no GitHub sign in of any kind, so this control is never
    /// gated on `gh`.
    private var openButton: some View {
        Button("Open on GitHub", systemImage: "arrow.up.forward.app") {
            GitHubBridge.open(pullRequest.url)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help("Open #\(pullRequest.number) on GitHub")
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
        VStack(alignment: .leading, spacing: 1) {
            Text(status.text)
                .font(isPending ? Typo.heading : Typo.title)
                .foregroundStyle(tint ?? Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            if let detail = status.detail {
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

    /// The one prominent control, whichever it is, and the merge methods beside it.
    ///
    /// The primary slot belongs to whatever the state is actually asking for. With local work in
    /// the worktree that is not Merge: merging now would land the pull request WITHOUT what the
    /// reader is looking at and delete the branch it was on. So the primary swaps to Commit and
    /// push, and merging stays exactly one click away in the menu beside it, which already listed
    /// all three methods and already opens the same confirmation. Nothing is taken away; what
    /// changes is which of the two the strip is pointing at.
    @ViewBuilder
    private var trailing: some View {
        if isWorking {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Working")
        } else if pullRequest.isOpen {
            HStack(spacing: Metrics.spacingTight) {
                if status.remedy == .merge { mergeButton } else { pushButton }
                mergeMenu
            }
            .fixedSize()
        }
        // A merged or closed pull request needs no control here. The headline says which of the
        // two it is and the strip carries its colour, so a capsule repeating the same word was
        // only ever taking the place of the button that used to be there.
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
            .tint(tint ?? Palette.accentFill)
            .controlSize(.regular)
            .help(
                "Ask this workspace's agent to \(pushLabel.lowercased()) branch "
                    + "\(pullRequest.branch.isEmpty ? "this branch" : pullRequest.branch), so "
                    + "#\(pullRequest.number) is what is on this disk."
            )
    }

    private var pushLabel: String {
        status.remedy == .push ? "Push" : "Commit and push"
    }

    /// The other two merge methods, and while there is local work the way to merge at all.
    private var mergeMenu: some View {
        Menu {
            ForEach(GitHub.MergeMethod.allCases, id: \.self) { method in
                Button(method.label) { propose(method) }
            }
        } label: {
            Label("Choose a merge method", systemImage: "chevron.down")
        }
        .labelStyle(.iconOnly)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // The state's colour rather than a neutral grey. It stands beside a filled button in
        // that colour and belongs to it, and a grey chevron a few points off a teal capsule
        // reads as a stray control that wandered into the strip.
        .foregroundStyle(tint ?? Palette.accent)
        .controlSize(.small)
        .disabled(!status.canMerge)
        .help(status.blockedReason ?? "Merge #\(pullRequest.number), by whichever method")
    }

    /// The one prominent control in the inspector, and the only solid colour in the strip.
    ///
    /// A real `Button` rather than a `Menu` with a primary action. A menu styled `.button` ignores
    /// `.borderedProminent` and the tint under it on this SDK and comes out as the same neutral
    /// capsule as every other control in the bar, which is exactly the signal this control exists
    /// to carry. The other two methods moved to the chevron beside it, which stays a menu and stays
    /// quiet because it is not the thing being pointed at.
    ///
    /// Always explicitly tinted, and the tint does take effect: measured on this SDK the fill
    /// comes out at the tint's own value, where an untinted `.borderedProminent` comes out at
    /// `#3478F6`, the system accent, which is whatever blue or pink the user set in General. The
    /// fill is the state's own colour instead, so the strip is one decision from end to end and a
    /// red bar ends in a red button. Failing checks do not block merging, which is the whole
    /// reason that has to hold.
    ///
    /// The one thing no tint survives is the window losing key. AppKit draws every prominent
    /// button in an inactive window as a neutral glass capsule, this one included, and there is no
    /// override for it short of building the control by hand. That is the platform being
    /// consistent rather than a bug here, and it is worth knowing before reading a screenshot of
    /// this strip: a grey Merge button means the screenshot was taken with another app in front.
    ///
    /// Every path through it opens the confirmation. The button proposes a squash merge because
    /// that is what it says; nothing here ever performs one.
    private var mergeButton: some View {
        Button("Merge", systemImage: "arrow.triangle.merge") { propose(.squash) }
            .buttonStyle(.borderedProminent)
            .tint(tint ?? Palette.accentFill)
            .controlSize(.regular)
            .disabled(!status.canMerge)
            // Disabled controls do not explain themselves, and "why is this greyed out" is the
            // whole question a blocked pull request raises.
            .help(status.blockedReason ?? "Squash and merge, or choose another method")
    }

    // MARK: - Text

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

    /// Merging is the one thing in this strip that genuinely needs `gh`, so it is the one thing
    /// gated on it. Opening the page, copying the link and sharing it are ordinary URL handling
    /// and work signed out.
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
