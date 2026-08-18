import SwiftUI
import BatonCore

/// The centre column: where you are, which conversation you are in, what was said, and what you are
/// about to say.
///
/// The four pieces are stacked rather than nested because each one owns a different lifetime. The
/// header follows the workspace, the tabs follow the session list, and the transcript and the
/// composer follow the active session, which is why they are handed a transcript instead of
/// reaching for one themselves.
struct WorkspaceDetailView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: WorkspaceModel

    /// How much room the bottom panel takes when it is open. Roughly fifteen lines of terminal,
    /// which is enough to watch a build without burying the transcript.
    private static let bottomPanelHeight: CGFloat = 260

    /// The transcript reports whether the user has scrolled away from the newest row. Until it
    /// does, the unread pill is offered whenever there is anything unread.
    @State private var isTranscriptScrolledUp = true

    var body: some View {
        VStack(spacing: 0) {
            SessionTabsView(model: model)

            if let transcript = model.activeTranscript {
                TranscriptView(
                    transcript: transcript,
                    isRunningSetup: model.isRunningSetup
                ) { isTranscriptScrolledUp = $0 }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                ComposerView(
                    transcript: transcript,
                    model: model,
                    isScrolledUp: isTranscriptScrolledUp
                )
            } else if model.isRunningSetup {
                setupState
            } else {
                emptyState
            }

            // The panel keeps its own tab strip visible while collapsed, so it is always in the
            // stack and only its content takes room. The sidebar and inspector are placed by
            // RootView, which is why neither appears here.
            BottomPanelView(model: model)
                .frame(height: app.isBottomPanelVisible ? Self.bottomPanelHeight : nil)
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
