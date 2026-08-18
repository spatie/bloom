import SwiftUI

/// What the pane shows with no session behind it. Deliberately quiet: an empty transcript is a
/// normal state, not a problem to be announced.
struct EmptyTranscriptView: View {
    var body: some View {
        EmptyStateView(
            glyph: "text.alignleft",
            title: "No session",
            message: "Pick a workspace, or start a new one, and the agent's work shows up here."
        )
        .background(Palette.surface)
    }
}
