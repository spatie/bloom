import BloomCore

/// What the footer can ask the prompt above it to do.
///
/// The footer is only the row of controls: it holds no draft, because in a conversation the draft
/// belongs to a transcript and in the create window to a workspace that does not exist yet. Both of
/// the things it can put INTO that draft (a file through the paperclip, a quick prompt through the
/// panel beside it) are `ComposerPrompt`'s business, so they are handed down as one value rather
/// than as a growing list of closures on the footer's builder.
@MainActor
struct ComposerPromptActions {
    /// The paperclip: opens the file panel, and writes what is chosen into the draft at the caret.
    var attach: @MainActor () -> Void
    /// A quick prompt written into the draft at the caret, and nothing else: this is the writing
    /// half only. What a chosen prompt actually does is `QuickPromptDelivery`, decided by whoever
    /// owns the draft, because sending it and opening a chat for it are both things this surface
    /// has no way to do. `ComposerView.fire` is that decision made; the create window has neither
    /// of the other two routes and so only ever calls this.
    var insert: @MainActor (QuickPrompt) -> Void
}
