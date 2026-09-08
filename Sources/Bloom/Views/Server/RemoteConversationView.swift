import SwiftUI
import BloomCore

/// Selects the server-backed presentation model. All conversation UI belongs to ChatPaneView.
struct RemoteConversationView: View {
    @Bindable var model: ServerWindowModel
    @Environment(AppModel.self) private var app
    @State private var transcript: TranscriptModel?

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.error {
                HStack {
                    Text(error).textSelection(.enabled)
                    Spacer()
                    if !model.isConnected { Button("Reconnect") { Task { await model.connect() } } }
                }.font(Typo.caption).padding().background(Palette.surfaceSunken)
            }
            if let transcript {
                ChatPaneView(transcript: transcript, model: nil, pane: transcript.session.id.rawValue)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: (model.selectedSessionID?.rawValue ?? "") + (model.selectedWorkspace?.id.rawValue ?? "") + String(model.isConnected)) {
            transcript = model.conversation(app: app)
        }
        .environment(\.markdownLinkActions, TranscriptLinkActions(
            identity: .workspace(model.selectedWorkspace?.id, pane: "remote"),
            open: { url, _ in Task { await model.preview(url) } },
            items: { _ in [TranscriptLinkItem(title: "Open Preview", target: .browserTab)] },
            openFile: { model.openFile($0); app.isInspectorVisible = true }
        ))
    }
}
