import SwiftUI
import BatonCore

/// The strip when a pull request already exists: its number, how CI feels about it, and the one
/// button that finishes the job.
struct PullRequestSummary: View {
    var pullRequest: PullRequest
    var baseBranch: String
    var isWorking: Bool
    var onMerge: (GitHub.MergeMethod) -> Void

    @State private var pendingMerge: GitHub.MergeMethod?

    var body: some View {
        HStack(spacing: InspectorLayout.gap) {
            Button {
                GitHubBridge.open(pullRequest.url)
            } label: {
                Chip(
                    text: "#\(pullRequest.number)",
                    systemImage: "arrow.triangle.pull",
                    tint: Palette.accent,
                    background: Palette.accent.opacity(InspectorLayout.tintOpacity)
                )
            }
            .buttonStyle(.plain)
            .help(pullRequest.title)
            .accessibilityLabel("Open pull request \(pullRequest.number)")

            if pullRequest.isDraft {
                Chip(text: "Draft")
            }

            // The one thing in the strip that can be any length, so it is the one that gives way
            // rather than pushing the merge button off the edge of a narrow pane.
            Text(statusText)
                .font(Typo.caption)
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
                .help(statusText)

            Spacer(minLength: Metrics.spacingSmall)

            if isWorking {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Working")
            } else if pullRequest.state.uppercased() == "OPEN" {
                mergeButton
            } else {
                Chip(text: pullRequest.state.capitalized)
            }
        }
        // Attached to the merge button's own row, so the dialog animates out of the control that
        // asked for it.
        .confirmationDialog(
            "Merge pull request #\(pullRequest.number)?",
            isPresented: $pendingMerge.isPresent(),
            presenting: pendingMerge
        ) { method in
            Button(Self.label(for: method), role: .destructive) { onMerge(method) }
            Button("Cancel", role: .cancel) {}
        } message: { method in
            Text("\(Self.label(for: method)) into \(baseBranch) and delete the branch.")
        }
    }

    /// The one prominent control in the inspector. It is a real bordered prominent button, so it
    /// carries the user's accent colour and the pressed and disabled states that come with it,
    /// rather than a rectangle painted to look like a button.
    private var mergeButton: some View {
        Menu {
            Button("Merge commit") { pendingMerge = .merge }
            Button("Squash and merge") { pendingMerge = .squash }
            Button("Rebase and merge") { pendingMerge = .rebase }
        } label: {
            Text("Merge")
        } primaryAction: {
            pendingMerge = .squash
        }
        .menuStyle(.button)
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .fixedSize()
        .help("Squash and merge, or choose another method")
    }

    private var statusText: String {
        if !pullRequest.checksSummary.isEmpty { return pullRequest.checksSummary }
        if let decision = pullRequest.reviewDecision, !decision.isEmpty {
            return decision.replacing("_", with: " ").capitalized
        }
        return pullRequest.title
    }

    private var statusColor: Color {
        switch pullRequest.checks {
        case .passing: Palette.positive
        case .failing: Palette.negative
        case .pending: Palette.warning
        case .none: Palette.textSecondary
        }
    }

    static func label(for method: GitHub.MergeMethod) -> String {
        switch method {
        case .merge: "Merge commit"
        case .squash: "Squash and merge"
        case .rebase: "Rebase and merge"
        }
    }
}
