import SwiftUI

/// What a loaded but empty transcript says.
///
/// A blank white rectangle above the composer reads as a rendering failure, and it is the first
/// thing a new workspace shows: the session exists, the setup script is still running, and nothing
/// has happened yet. Saying which of those it is costs one sentence.
struct TranscriptPlaceholderView: View {
    var isRunningSetup: Bool

    var body: some View {
        if isRunningSetup {
            EmptyStateView(
                glyph: "gearshape.2",
                title: "Setting up the workspace",
                message: "The setup script is still running. Ask for something now and it goes as soon as that finishes."
            )
        } else {
            EmptyStateView(
                glyph: "text.alignleft",
                title: "Nothing here yet",
                message: "Ask for something below and the agent's work shows up here."
            )
        }
    }
}
