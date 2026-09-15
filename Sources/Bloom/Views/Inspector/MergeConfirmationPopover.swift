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
    /// The fill of the merge control this is attached to, so the press that asks and the press
    /// that answers are one colour. It was `Palette.positive` for every state, which put a green
    /// button under an amber "Checks running" one and made the popover read as a second decision.
    let tint: Color
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ConfirmationPopover(
            title: pullRequest.mergeConfirmationTitle(base: baseBranch),
            confirmLabel: method.label,
            tint: tint,
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
