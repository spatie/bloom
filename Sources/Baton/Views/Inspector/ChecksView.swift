import SwiftUI
import BatonCore

/// CI for the current branch, grouped the way GitHub groups it.
///
/// The list polls only while it is on screen. A dozen workspaces each asking gh for check runs
/// every twenty seconds would be a dozen subprocesses a minute for panels nobody is looking at.
struct ChecksView: View {
    let model: WorkspaceModel

    @State private var runs: [CheckRun] = []
    @State private var hasLoaded = false

    private var groups: [(workflow: String, runs: [CheckRun])] {
        let grouped = Dictionary(grouping: runs) { $0.workflowName ?? "Checks" }
        return grouped
            .map { (workflow: $0.key, runs: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.workflow < $1.workflow }
    }

    var body: some View {
        VStack(spacing: 0) {
            summary
            Hairline()
            if runs.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups, id: \.workflow) { group in
                            Section {
                                ForEach(group.runs) { run in
                                    row(run)
                                }
                            } header: {
                                header(group.workflow, runs: group.runs)
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: model.workspace.id) {
            while !Task.isCancelled {
                runs = await GitHubBridge.checks(
                    branch: model.workspace.branch, worktree: model.workspace.path
                )
                hasLoaded = true
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    // MARK: - Header

    private var summary: some View {
        let rollup = GitHub.rollup(runs)
        return HStack(spacing: 6) {
            Circle()
                .fill(color(for: rollup.0))
                .frame(width: 6, height: 6)
            Text(runs.isEmpty && !hasLoaded ? "Loading checks" : rollup.1)
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("\(runs.count)")
                .font(Typo.micro)
                .monospacedDigit()
                .foregroundStyle(Palette.textTertiary)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            if hasLoaded {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 16, weight: .light))
                    .foregroundStyle(Palette.textTertiary)
                Text("No checks reported for this branch")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .multilineTextAlignment(.center)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func header(_ workflow: String, runs: [CheckRun]) -> some View {
        HStack(spacing: 4) {
            Text(workflow)
                .font(Typo.micro)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("\(runs.count)")
                .font(Typo.micro)
                .monospacedDigit()
        }
        .foregroundStyle(Palette.textTertiary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceSunken)
    }

    // MARK: - Rows

    private func row(_ run: CheckRun) -> some View {
        Button {
            if let url = run.detailsURL { GitHubBridge.open(url) }
        } label: {
            HStack(spacing: 6) {
                glyph(for: Self.state(of: run))
                VStack(alignment: .leading, spacing: 0) {
                    Text(run.name)
                        .font(Typo.label)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    if let workflow = run.workflowName, workflow != run.name {
                        Text(workflow)
                            .font(Typo.micro)
                            .foregroundStyle(Palette.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let duration = Self.duration(of: run) {
                    Text(duration)
                        .font(Typo.micro)
                        .monospacedDigit()
                        .foregroundStyle(Palette.textTertiary)
                }
                if run.detailsURL != nil {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Palette.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(run.detailsURL ?? run.name)
    }

    @ViewBuilder
    private func glyph(for state: CheckState) -> some View {
        switch state {
        case .running:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 14, height: 14)
        case .passed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Palette.positive)
                .frame(width: 14, height: 14)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Palette.negative)
                .frame(width: 14, height: 14)
        case .skipped:
            Image(systemName: "minus.circle")
                .foregroundStyle(Palette.textTertiary)
                .frame(width: 14, height: 14)
        case .neutral:
            Image(systemName: "circle")
                .foregroundStyle(Palette.textTertiary)
                .frame(width: 14, height: 14)
        }
    }

    // MARK: - Classification

    enum CheckState {
        case running
        case passed
        case failed
        case skipped
        case neutral
    }

    /// gh reports two shapes through one field, and an in-flight run has no conclusion at all,
    /// so status is only trusted once a conclusion exists to contradict it.
    static func state(of run: CheckRun) -> CheckState {
        guard let conclusion = run.conclusion?.uppercased() else {
            return run.status.uppercased() == "COMPLETED" ? .neutral : .running
        }
        return switch conclusion {
        case "SUCCESS": .passed
        case "SKIPPED": .skipped
        case "NEUTRAL": .neutral
        case "PENDING", "EXPECTED", "QUEUED", "IN_PROGRESS", "WAITING": .running
        case "FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED",
             "STARTUP_FAILURE", "STALE": .failed
        default: .neutral
        }
    }

    private static func duration(of run: CheckRun) -> String? {
        guard let started = run.startedAt, let completed = run.completedAt else { return nil }
        let seconds = Int(completed.timeIntervalSince(started).rounded())
        guard seconds >= 0 else { return nil }
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m \(seconds % 60)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private func color(for checks: PullRequest.Checks) -> Color {
        switch checks {
        case .passing: Palette.positive
        case .failing: Palette.negative
        case .pending: Palette.warning
        case .none: Palette.textTertiary
        }
    }
}
