import SwiftUI
import BloomCore

/// File and browser reviews use the conversation's real draft and send path. Reserving this
/// space when the pane opens means adding a comment cannot change the content's viewport.
struct ReviewPaneComposer<Model: WorkspacePaneModel>: View {
    @Bindable var model: Model
    var room: ComposerRoom
    var destinationID: SessionID?

    @AppStorage(ChatTextSize.defaultsKey) private var textSize = ChatTextSize.defaultChoice
    @AppStorage(ChatFont.defaultsKey) private var chatFontID = ChatFont.standardID
    @AppStorage(ChatLineHeight.defaultsKey) private var lineHeight = ChatLineHeight.defaultChoice

    private var destination: Session? {
        if let destinationID { return model.sessions.first { $0.id == destinationID } }
        return model.reviewDestination
    }

    var body: some View {
        Group {
            if let destination, let transcript = model.existingTranscript(for: destination.id) {
                ComposerView(
                    transcript: transcript, model: model.localWorkspaceModel, room: room,
                    destinationLabel: ReviewDestination.label(for: destination.title),
                    destinations: destinationID == nil
                        ? model.sessions.map { ComposerDestination(id: $0.id, title: $0.title) } : [],
                    onSelectDestination: choose
                )
                .environment(\.fontScale, textSize.scale)
                .environment(\.chatFont, ChatFont(rawValue: chatFontID))
                .environment(\.chatLineHeight, lineHeight)
            }
        }
        .task(id: destination?.id) {
            guard let destination else { return }
            model.prepareTranscript(for: destination.id)
        }
    }

    private func choose(_ id: SessionID) {
        guard model.reviewDestinationID != id else { return }
        model.reviewDestinationID = id
        model.prepareTranscript(for: id)
    }
}
