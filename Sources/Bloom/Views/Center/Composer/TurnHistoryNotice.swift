import SwiftUI
import BloomCore

struct TurnHistoryNotice: View {
    var transcript: TranscriptModel
    @Environment(AppModel.self) private var app
    @State private var confirmsRecovery = false

    var body: some View {
        if transcript.history.pendingRewind != nil {
            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                Text("A rewind needs recovery before this workspace can continue.")
                    .font(Typo.label)
                if let failure = transcript.history.failure { Text(failure).font(Typo.caption).textSelection(.enabled) }
                Button("Resolve Rewind") { confirmsRecovery = true }
                    .disabled(transcript.history.isRewinding)
            }
            .padding(Metrics.spacingSmall)
            .alert("Resolve the interrupted rewind?", isPresented: $confirmsRecovery) {
                Button("Cancel", role: .cancel) {}
                Button("Resolve Rewind") {
                    Task { await transcript.history.recover(transcript: transcript, app: app) }
                }
            } message: {
                Text("Bloom checks the agent's history, then completes the rewind or restores the saved files and staging. Later file edits may be replaced. Stop terminal commands first.")
            }
        } else if let failure = transcript.history.failure {
            HStack(alignment: .top, spacing: Metrics.spacing) {
                Text(failure).font(Typo.caption).textSelection(.enabled)
                Spacer(minLength: 0)
                if let id = transcript.history.blockingSessionID, let workspace = transcript.workspace,
                   let model = app.existingModel(for: workspace.id) {
                    Button("Open Recovery Chat") { WorkspaceTabsStore.shared.reveal(.chat(id), in: model) }
                } else {
                    Button("Dismiss") { transcript.history.failure = nil }
                }
            }
            .padding(Metrics.spacingSmall)
        }
    }
}
