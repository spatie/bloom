import SwiftUI
import BloomCore

/// Ask conversations share the app's tab chrome, visible once a second conversation is open.
struct AskView: View {
    @Environment(AppModel.self) private var app

    private var textSize: ChatTextSize { ColourThemePreference.shared.chatTextSize }
    private var chatFontID: String { ColourThemePreference.shared.chatFont }
    private var lineHeight: ChatLineHeight { ColourThemePreference.shared.chatLineHeight }

    var body: some View {
        let isStripShown = app.ask.sessions.count > 1
        // The same split the centre column makes: each busy tab with a strip, the top edge
        // without one, never both. See `BusySignalPlacement`.
        let busy = BusySignalPlacement.resolve(
            isStripShown: isStripShown,
            tabs: app.ask.sessions.map(\.id),
            selected: app.ask.selectedID,
            isRunning: app.ask.isRunning
        )
        VStack(spacing: 0) {
            if isStripShown { AskTabStrip(busy: busy) }
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
        // A lone conversation has no tab to sweep, so its segment runs along the top edge, the
        // way a workspace's column does. `.identity`, so it leaves at once when the strip arrives.
        .overlay(alignment: .top) {
            if !isStripShown {
                ColumnBusySignal(isActive: busy.showsColumnTop).transition(.identity)
            }
        }
        // And VoiceOver hears it through the title bar, which says "Ask Bloom". See
        // `WindowTitleText.busySelection`.
        .onChange(of: busy.showsColumnTop, initial: true) { _, shows in
            WindowTitleText.shared.setBusy(shows, for: .ask)
        }
        .onDisappear { WindowTitleText.shared.setBusy(false, for: .ask) }
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
