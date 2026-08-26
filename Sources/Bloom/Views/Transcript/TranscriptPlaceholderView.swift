import SwiftUI

/// What a loaded but empty transcript says.
///
/// A blank white rectangle above the composer reads as a rendering failure, and it is the first
/// thing a new workspace shows: the session exists, the setup script is still running, and nothing
/// has happened yet. Saying which of those it is costs one sentence.
struct TranscriptPlaceholderView: View {
    var isRunningSetup: Bool

    /// What to say instead of "Nothing here yet", for a conversation whose empty state is a
    /// different sentence.
    ///
    /// Ask Bloom had its own `EmptyStateView` laid over the transcript in a `ZStack`, and the
    /// transcript went on drawing this one underneath: two headings and two paragraphs on top of
    /// each other. One pane shows one empty state, so the caller replaces the words rather than
    /// covering them up. Setting up still wins over both, because it is the more urgent thing to
    /// say and it is temporary.
    var emptyState: TranscriptEmptyState?

    var body: some View {
        if isRunningSetup {
            EmptyStateView(
                glyph: "gearshape.2",
                title: "Setting up the workspace",
                message: "The setup script is still running. Ask for something now and it goes as soon as that finishes."
            )
        } else if let emptyState {
            EmptyStateView(glyph: emptyState.glyph, title: emptyState.title, message: emptyState.message)
        } else {
            EmptyStateView(
                glyph: "text.alignleft",
                title: "Nothing here yet",
                message: "Ask for something below and the agent's work shows up here."
            )
        }
    }
}

/// The words an empty transcript shows, for the panes that have their own.
struct TranscriptEmptyState: Equatable {
    var glyph: String
    var title: String
    var message: String
}
