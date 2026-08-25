import Foundation
import BloomCore

/// The dialog `QuickPromptDeletion` is worn in.
///
/// The words are in `BloomCore`, where they can be tested; only the shape is here, because
/// `Confirmation` is a piece of this app's chrome and the core does not know about dialogs. This is
/// `ProjectRemoval.confirmation(for:workspaces:runningAgents:)` again, deliberately: the app asks
/// eleven of these questions and they are meant to look and read alike.
extension QuickPromptDeletion {
    static func confirmation(for prompt: QuickPrompt) -> Confirmation {
        Confirmation(
            title: title(for: prompt.resolvedName),
            message: message,
            confirmLabel: confirmLabel,
            cancelLabel: cancelLabel
        )
    }
}
