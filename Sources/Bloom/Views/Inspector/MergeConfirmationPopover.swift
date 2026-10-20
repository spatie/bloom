import SwiftUI
import BloomCore

/// A confirmation attached to the merge control, keeping the chat and diff visible.
struct MergeConfirmationPopover: View {
    let pullRequest: PullRequest
    let baseBranch: String
    let localWork: LocalWork?
    let method: GitHub.MergeMethod
    let execution: MergeExecution
    let onChooseExecution: (MergeExecution) -> Void
    let deletesBranch: Bool
    let canMerge: Bool
    /// The fill of the merge control this is attached to, so the press that asks and the press
    /// that answers are one colour. It was `Palette.positive` for every state, which put a green
    /// button under an amber "Checks running" one and made the popover read as a second decision.
    let tint: Color
    /// The squash commit message, or nil for any other method or one left as proposed.
    let onConfirm: (SquashCommitMessage?) -> Void
    let onCancel: () -> Void

    @State private var subject = ""
    @State private var messageBody = ""

    private var proposed: SquashCommitMessage { .proposed(for: pullRequest) }

    var body: some View {
        ConfirmationPopover(
            title: pullRequest.mergeConfirmationTitle(base: pullRequest.baseBranch ?? baseBranch),
            confirmLabel: execution == .direct ? method.label : "Ask agent to merge",
            tint: tint,
            canConfirm: canMerge && (execution == .agent || canMergeDirectly),
            onConfirm: {
                let message = SquashCommitMessage(subject: subject, body: messageBody)
                onConfirm(method == .squash ? message.edited(from: proposed) : nil)
            },
            onCancel: onCancel,
            width: 380
        ) {
            Picker("Merge using", selection: executionBinding) {
                ForEach(MergeExecution.allCases, id: \.self) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .pickerStyle(.radioGroup)

            if method == .squash {
                VStack(alignment: .leading, spacing: Metrics.spacingWide) {
                    TextField("Commit subject", text: $subject)
                        .textFieldStyle(.roundedBorder)
                    TextField("Commit body, empty for GitHub's own", text: $messageBody, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...8)
                }
                .onAppear { subject = proposed.subject }
            }

            ForEach(pullRequest.mergeWarnings(base: pullRequest.baseBranch ?? baseBranch, local: localWork), id: \.self) { warning in
                Text(warning)
                    .foregroundStyle(Palette.negative)
            }

            if execution == .direct {
                Text("Bloom will run gh pr merge with the selected \(method.label.lowercased()) method. GitHub may queue the merge if this repository requires it.")
                Text("Bloom will not delete the branch or change this checkout. GitHub may delete the remote branch if the repository is configured to do so.")
                    .foregroundStyle(.secondary)
                if !canMergeDirectly {
                    Text("Refresh this pull request before merging directly.")
                        .foregroundStyle(Palette.negative)
                }
            } else {
                Text(pullRequest.mergeConfirmationMessage)

                if let deletion = pullRequest.mergeBranchDeletionMessage(deletesBranch: deletesBranch) {
                    Text(deletion)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var canMergeDirectly: Bool {
        pullRequest.headRevision != nil && pullRequest.baseBranch != nil
    }

    private var executionBinding: Binding<MergeExecution> {
        Binding(get: { execution }, set: { onChooseExecution($0) })
    }
}
