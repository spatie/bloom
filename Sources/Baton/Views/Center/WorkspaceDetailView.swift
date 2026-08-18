import SwiftUI
import BatonCore

/// The centre column: which conversation you are in, what was said, and what you are about to say.
///
/// The three pieces are stacked rather than nested because each one owns a different lifetime. The
/// tabs follow the session list, and the transcript and the composer follow the active session,
/// which is why they are handed a transcript instead of reaching for one themselves. The terminal
/// panel used to sit under all of it and now lives at the bottom of the inspector, where you can
/// watch a build without the transcript giving up a third of its height.
struct WorkspaceDetailView: View {
    @Bindable var model: WorkspaceModel

    /// The transcript reports whether the user has scrolled away from the newest row. Until it
    /// does, the unread pill is offered whenever there is anything unread.
    @State private var isTranscriptScrolledUp = true

    /// What the transcript and the composer were given between them, which is what caps how far
    /// the divider between the two can be dragged.
    @State private var conversationHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            SessionTabsView(model: model)

            if let transcript = model.activeTranscript {
                // Nested so the two views that share a draggable divider also share one measured
                // height. It is the composer that needs the number, to know when it has taken all
                // the room it may take, and only this level knows what the pair were given.
                VStack(spacing: 0) {
                    TranscriptView(
                        transcript: transcript,
                        isRunningSetup: model.isRunningSetup
                    ) { isTranscriptScrolledUp = $0 }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    ComposerView(
                        transcript: transcript,
                        model: model,
                        isScrolledUp: isTranscriptScrolledUp,
                        availableHeight: conversationHeight
                    )
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    conversationHeight = $0
                }
            } else if model.isRunningSetup {
                setupState
            } else {
                emptyState
            }
        }
        .background(Palette.windowBackground)
        .task(id: model.workspace.id) { await model.onAppear() }
    }

    /// A fresh workspace runs its setup script before anything else, and that can take minutes on a
    /// large repository. Saying so beats an empty rectangle that looks like a failure.
    private var setupState: some View {
        EmptyStateView(
            glyph: "gearshape.2",
            title: "Setting up the workspace",
            message: "The setup script is still running. The first session opens as soon as it finishes."
        )
        .background(Palette.surface)
    }

    /// Sessions are loaded asynchronously, so there is a moment with none, and archiving the last
    /// one leaves the workspace here for good.
    private var emptyState: some View {
        EmptyStateView(
            glyph: "bubble.left.and.bubble.right",
            title: "No session in this workspace",
            message: "Sessions share the worktree but not the conversation, so a new one starts with a clean context.",
            actionTitle: "Start a session",
            action: createSession
        )
    }

    private func createSession() {
        Task { await model.createSession() }
    }
}
