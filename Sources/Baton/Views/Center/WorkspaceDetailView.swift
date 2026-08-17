import SwiftUI
import BatonCore

/// The centre column: where you are, which conversation you are in, what was said, and what you
/// are about to say.
///
/// The four pieces are stacked rather than nested because each one owns a different lifetime. The
/// header follows the workspace, the tabs follow the session list, and the transcript and the
/// composer follow the active session, which is why they are handed a transcript instead of
/// reaching for one themselves.
struct WorkspaceDetailView: View {
    @Bindable var model: WorkspaceModel

    /// The transcript reports whether the user has scrolled away from the newest row. Until it
    /// does, the unread pill is offered whenever there is anything unread.
    @State private var isTranscriptScrolledUp = true

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeaderView(model: model)
            SessionTabsView(model: model)

            if let transcript = model.activeTranscript {
                TranscriptView(transcript: transcript)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                ComposerView(
                    transcript: transcript,
                    model: model,
                    isScrolledUp: isTranscriptScrolledUp
                )
            } else {
                emptyState
            }
        }
        .background(Palette.windowBackground)
        .task(id: model.workspace.id) { await model.onAppear() }
    }

    /// Sessions are loaded asynchronously, so there is a moment with none, and archiving the last
    /// one leaves the workspace here for good.
    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Text("No session in this workspace")
                .font(Typo.body)
                .foregroundStyle(Palette.textSecondary)
            Button("Start a session") {
                Task { await model.createSession() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
