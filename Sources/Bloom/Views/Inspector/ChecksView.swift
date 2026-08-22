import SwiftUI
import BloomCore

/// CI for the current branch, grouped the way GitHub groups it.
///
/// The list polls only while it is on screen. A dozen workspaces each asking gh for check runs
/// every twenty seconds would be a dozen subprocesses a minute for panels nobody is looking at.
struct ChecksView: View {
    let model: WorkspaceModel

    /// How often GitHub is asked again while the tab is on screen.
    private static let pollInterval = Duration.seconds(20)

    @State private var runs: [CheckRun] = []
    @State private var groups: [CheckRunGroup] = []
    @State private var hasLoaded = false
    @State private var hovered: String?
    @State private var github: GitHubAvailability.State = .unknown
    /// Bumped to restart the poll at once, rather than waiting out the twenty seconds, when
    /// something has happened that would change the answer.
    @State private var reload = 0
    /// The gh call behind the hand-off button, and the flag that stops a second press landing on
    /// top of the first. One per pane rather than one per row, because only one check is ever
    /// being fetched at a time.
    @State private var sender = CheckFailureSender()

    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            // With nothing to roll up the strip only repeats the empty state's own title back at
            // it, so the pane says "No checks" twice under two different type sizes.
            if !runs.isEmpty {
                summary
                Hairline()
            }
            if runs.isEmpty {
                empty
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: "\(model.workspace.id)|\(reload)") { await poll() }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.runs) { run in
                            row(run)
                        }
                    } header: {
                        header(group)
                    }
                }
            }
            .padding(.bottom, Metrics.spacingSmall)
        }
    }

    private func row(_ run: CheckRun) -> some View {
        // Nil rather than a button that would explain itself: a check that passed has nothing to
        // hand over, and a workspace with no conversation has nowhere to hand it.
        var onSend: (@MainActor () -> Void)?
        if CheckFailureSender.canSend(run), model.activeSession != nil {
            onSend = { send(run) }
        }

        return CheckRunRow(
            run: run,
            isHovered: hovered == run.id,
            isSending: sender.isSending(run),
            onSend: onSend
        )
            // Nothing here is selectable, but a row that opens a browser has to say so on hover,
            // which is what the rest of the inspector's lists do. The fill is inset from the pane
            // edge the way a source list's is, and the row pays the rest of the shared inset.
            .rowBackground(isSelected: false, isHovered: hovered == run.id)
            .padding(.horizontal, Metrics.spacingSmall)
            .onHoverChange { hovering in
                hovered = hovering ? run.id : (hovered == run.id ? nil : hovered)
            }
    }

    // MARK: - Header

    private var summary: some View {
        let rollup = GitHub.rollup(runs)
        return HStack(spacing: InspectorLayout.gap) {
            Circle()
                .fill(color(for: rollup.0))
                .frame(width: Metrics.dot, height: Metrics.dot)
                .accessibilityHidden(true)
            Text(summaryText(rollup.1))
                .font(Typo.body)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Text("\(runs.count)")
                .font(Typo.micro)
                .monospacedDigit()
                .foregroundStyle(Palette.textTertiary)
                .accessibilityLabel("\(runs.count) checks")
        }
        .padding(.horizontal, InspectorLayout.inset)
        // The height every other strip in this column is, rather than a list row's.
        .frame(height: InspectorLayout.barHeight)
    }

    /// Filled rather than left at its natural height, so it centres in the pane the way the
    /// changed file list's empty state does. Top aligned it read as a paragraph that had lost
    /// its heading.
    private var empty: some View {
        emptyContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var emptyContent: some View {
        if !github.isUsable {
            // Honest rather than alarming: an empty list here means Bloom could not ask, not that
            // GitHub reported nothing. The two reasons are different problems with different
            // fixes, so they get different sentences.
            VStack(spacing: Metrics.gutter) {
                EmptyStateView(
                    glyph: "questionmark.circle",
                    title: github == .notInstalled ? "The GitHub CLI is not installed" : "GitHub is not connected",
                    message: github == .notInstalled
                        ? "Checks come from GitHub through the gh command, and it is not on this Mac."
                        : "Checks come from GitHub through the gh command, and it is signed out."
                )
                // A deliberate press, which is the only thing that may raise the sheet.
                Button(github == .notInstalled ? "Install the GitHub CLI" : "Connect GitHub") {
                    // Through the gate rather than straight to the sheet, so a signed in machine
                    // simply reloads and a signed out one signs in and then reloads.
                    GitHubSignIn.shared.run(directory: model.workspace.path) { reload += 1 }
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accentFill)
            }
        } else if hasLoaded {
            EmptyStateView(
                glyph: "checkmark.seal",
                title: "No checks",
                message: "GitHub has not reported a check run for this branch."
            )
        } else {
            LoadingView("Asking GitHub")
        }
    }

    private func header(_ group: CheckRunGroup) -> some View {
        HStack(spacing: Metrics.spacingSmall) {
            Text(group.workflow)
                .font(Typo.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Text("\(group.runs.count)")
                .font(Typo.micro)
                .monospacedDigit()
        }
        .foregroundStyle(Palette.textTertiary)
        .padding(.horizontal, InspectorLayout.inset)
        .padding(.vertical, Metrics.spacingSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceSunken)
    }

    /// The header says which of the three things is true: nobody has asked yet, gh cannot be
    /// asked, or this is what GitHub said.
    private func summaryText(_ rollup: String) -> String {
        if !github.isUsable { return github == .notInstalled ? "No GitHub CLI" : "GitHub not connected" }
        return runs.isEmpty && !hasLoaded ? "Loading checks" : rollup
    }

    private func color(for checks: PullRequest.Checks) -> Color {
        switch checks {
        case .passing: Palette.positive
        case .failing: Palette.negative
        case .pending: Palette.warning
        case .none: Palette.textTertiary
        }
    }

    /// Fetches the failed run's log and puts it in the composer. See `CheckFailureSender`, which
    /// is where the gh call and every decision about the log live; this is the press.
    private func send(_ run: CheckRun) {
        Task {
            guard let failure = await sender.send(run, in: model) else { return }
            app.alert = BloomAlert(
                title: "That check was not sent to the agent", message: failure
            )
        }
    }

    // MARK: - Loading

    private func poll() async {
        while !Task.isCancelled {
            // Asked every pass rather than once: gh can be signed in from a terminal while this
            // tab is open, and the answer is cached, so this costs a subprocess only when it
            // has actually expired.
            let state = await GitHubAvailability.shared.check()
            github = state

            if state == .ready {
                let found = await GitHubBridge.checks(
                    branch: model.workspace.branch, worktree: model.workspace.path
                )
                runs = found
                groups = CheckRunGroup.build(from: found)
            }
            hasLoaded = true
            try? await Task.sleep(for: Self.pollInterval)
        }
    }
}
