import SwiftUI
import BloomCore

/// Resolves remote data for the same diff, file preview and composer used in local review panes.
struct RemoteReviewPane: View {
    @Bindable var server: ServerWindowModel
    @Environment(AppModel.self) private var app
    @State private var listing: RemoteWorkspaceFileListing?
    @State private var transcript: TranscriptModel?
    @State private var room = ComposerRoom()
    @AppStorage(ChatTextSize.defaultsKey) private var textSize = ChatTextSize.defaultChoice
    @AppStorage(ChatFont.defaultsKey) private var chatFontID = ChatFont.standardID
    @AppStorage(ChatLineHeight.defaultsKey) private var lineHeight = ChatLineHeight.defaultChoice

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let listing, listing.workspace.id == server.selectedWorkspace?.id, let path = server.review.selectedPath {
                    if let file = listing.changedFiles.first(where: { $0.path == path }) {
                        DiffView(model: listing, file: file)
                            .id(listing.workspace.id.rawValue + ":" + path)
                    } else if FileMediaView.isMedia(path: path) {
                        RemoteFilePreviewView(server: server, workspaceID: listing.workspace.id, path: path)
                    } else {
                        FilePreview(model: listing, path: path)
                            .id(listing.workspace.id.rawValue + ":" + path)
                    }
                } else {
                    EmptyStateView(glyph: "doc.text", title: "Select a file", message: "Pick a file in the inspector to review it.")
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let transcript {
                ComposerView(transcript: transcript, model: nil, room: room,
                    destinationLabel: ReviewDestination.label(for: transcript.session.title),
                    destinations: server.catalogue?.sessions.filter { $0.workspaceID == server.selectedWorkspace?.id }.map {
                        ComposerDestination(id: $0.id, title: $0.title)
                    } ?? [],
                    onSelectDestination: { app.selection = .remote($0) })
                    .environment(\.fontScale, textSize.scale)
                    .environment(\.chatFont, ChatFont(rawValue: chatFontID))
                    .environment(\.chatLineHeight, lineHeight)
            }
        }
        .onGeometryChange(for: CGFloat.self) { PaneMeasure.room($0.size.height) } action: { room.height = $0 }
        .background(Palette.surface)
        .task(id: server.selectedWorkspace?.id) {
            if let workspace = server.selectedWorkspace { listing = RemoteWorkspaceFileListing(workspace: workspace, server: server) }
        }
        .task(id: server.selectedSessionID) { transcript = server.conversation(app: app) }
    }
}
