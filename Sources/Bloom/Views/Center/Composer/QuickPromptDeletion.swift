import Foundation
import BloomCore

/// The dialog `QuickPromptDeletion` is worn in.
///
/// The words are in `BloomCore`, where they can be tested. The compact layout fits this short,
/// local action without making the quick prompt popover feel subordinate to a large alert.
extension QuickPromptDeletion {
    static func confirmation(for prompt: QuickPrompt) -> Confirmation {
        Confirmation(
            title: title(for: prompt.resolvedName),
            message: message,
            confirmLabel: confirmLabel,
            cancelLabel: cancelLabel,
            layout: .compact
        )
    }
}
