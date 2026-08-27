import BloomCore

/// The dialog `ReviewCommentDiscard` is worn in.
///
/// The words are in `BloomCore`, where a test can read them; only the shape is here, because
/// `Confirmation` is a piece of this app's chrome and the core does not know about dialogs. This
/// is `QuickPromptDeletion.confirmation(for:)` again, deliberately: the app asks a dozen of these
/// questions and they are meant to look and read alike, so a diff does not get a confirmation of
/// its own that differs from the rest by when it was written.
extension ReviewCommentDiscard {
    var confirmation: Confirmation {
        Confirmation(
            title: title,
            message: message,
            confirmLabel: confirmLabel,
            cancelLabel: cancelLabel
        )
    }
}
