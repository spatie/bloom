import SwiftUI
import BloomCore

/// A confirmation attached to the merge control, keeping the chat and diff visible.
struct MergeConfirmationPopover: View {
    let pullRequest: PullRequest
    let baseBranch: String
    let localWork: LocalWork?
    let method: GitHub.MergeMethod
    let deletesBranch: Bool
    let canMerge: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ConfirmationPopover(
            title: pullRequest.mergeConfirmationTitle(base: baseBranch),
            confirmLabel: method.label,
            tint: Palette.positive,
            canConfirm: canMerge,
            onConfirm: onConfirm,
            onCancel: onCancel
        ) {
            ForEach(pullRequest.mergeWarnings(base: baseBranch, local: localWork), id: \.self) { warning in
                Text(warning)
                    .foregroundStyle(Palette.negative)
            }

            Text(pullRequest.mergeConfirmationMessage)

            if let deletion = pullRequest.mergeBranchDeletionMessage(deletesBranch: deletesBranch) {
                Text(deletion)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
