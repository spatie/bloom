import SwiftUI
import BatonCore

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

    var body: some View {
        VStack(spacing: 0) {
            summary
            Hairline()
            if runs.isEmpty {
                empty
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: model.workspace.id) { await poll() }
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
        CheckRunRow(run: run)
            // Nothing here is selectable, but a row that opens a browser has to say so on hover,
            // which is what the rest of the inspector's lists do.
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
        .frame(height: Metrics.rowHeight)
    }

    @ViewBuilder
    private var empty: some View {
        if github == .unavailable {
            // Honest rather than alarming: an empty list here means Baton could not ask, not that
            // GitHub reported nothing.
            EmptyStateView(
                glyph: "questionmark.circle",
                title: "GitHub CLI unavailable",
                message: "Install gh and run gh auth login to see this branch's checks."
            )
        } else if hasLoaded {
            EmptyStateView(
                glyph: "checkmark.seal",
                title: "No checks",
                message: "GitHub has not reported a check run for this branch."
            )
        } else {
            LoadingView("Asking GitHub")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ group: CheckRunGroup) -> some View {
        HStack(spacing: Metrics.spacingSmall) {
            Text(group.workflow)
                .font(Typo.micro)
                .lineLimit(1)
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
        if github == .unavailable { return "GitHub CLI unavailable" }
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

    // MARK: - Loading

    private func poll() async {
        while !Task.isCancelled {
            // Asked every pass rather than once: gh can be signed in from a terminal while this
            // tab is open, and the answer is cached, so this costs a subprocess only when it
            // has actually expired.
            let ready = await GitHubAvailability.shared.isReady()
            github = ready ? .ready : .unavailable

            if ready {
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
