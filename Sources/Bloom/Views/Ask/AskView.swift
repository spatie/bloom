import SwiftUI
import BloomCore

/// Ask conversations share the app's tab chrome, visible once a second conversation is open.
struct AskView: View {
    @Environment(AppModel.self) private var app

    @AppStorage(ChatTextSize.defaultsKey) private var textSize = ChatTextSize.defaultChoice
    @AppStorage(ChatFont.defaultsKey) private var chatFontID = ChatFont.standardID
    @AppStorage(ChatLineHeight.defaultsKey) private var lineHeight = ChatLineHeight.defaultChoice

    var body: some View {
        VStack(spacing: 0) {
            if app.ask.sessions.count > 1 { AskTabStrip() }
            if let trouble = app.ask.trouble {
                EmptyStateView(
                    glyph: "exclamationmark.triangle",
                    title: "This conversation has nowhere to run",
                    message: trouble
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let transcript = app.ask.transcript {
                AskConversationView(transcript: transcript)
                    .id(transcript.session.id)
            } else {
                // The moment between the pane opening and the store answering. Nothing is drawn
                // rather than an empty state, because an empty state that appears for one frame
                // and is replaced reads as a fault.
                Color.clear
            }
        }
        .background(Palette.windowBackground)
        .overlay(alignment: .top) {
            if app.ask.sessions.count <= 1 {
                ActivityRule().frame(height: BusyCrest.thickness)
            }
        }
        .environment(\.fontScale, textSize.scale)
        .environment(\.chatFont, ChatFont(rawValue: chatFontID))
        .environment(\.chatLineHeight, lineHeight)
        // Not in a body: `open()` writes observed state and can create a session row.
        .task { await app.ask.open() }
        .confirmationDialog("Stop and close this conversation?", isPresented: Binding(
            get: { app.ask.closingID != nil }, set: { if !$0 { app.ask.closingID = nil } }
        ), titleVisibility: .visible) {
            Button("Stop and Close", role: .destructive) {
                if let id = app.ask.closingID { Task { await app.ask.close(id) } }
                app.ask.closingID = nil
            }
            Button("Cancel", role: .cancel) { app.ask.closingID = nil }
        } message: {
            Text("The agent will stop. The conversation will be archived.")
        }
    }

}

private struct AskConversationView: View {
    let transcript: TranscriptModel
    @State private var isTranscriptScrolledUp = false
    @State private var room = ComposerRoom()

    var body: some View {
        TranscriptView(transcript: transcript, emptyState: Self.opening) {
            isTranscriptScrolledUp = $0
        }
        .environment(\.composerRoom, room)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            ComposerDock(
                showsJumpToNewest: isTranscriptScrolledUp,
                onJumpToNewest: transcript.jumpToLiveEnd
            ) {
                ComposerView(
                    transcript: transcript,
                    model: nil,
                    room: room,
                    placeholder: AskConversation.placeholder
                )
            }
        }
        .onGeometryChange(for: CGFloat.self) { PaneMeasure.room($0.size.height) } action: {
            room.height = $0
        }
    }

    private static let opening = TranscriptEmptyState(
        glyph: PaneGlyph.chat,
        title: AskConversation.emptyHeading,
        message: AskConversation.emptyDetail
    )
}
