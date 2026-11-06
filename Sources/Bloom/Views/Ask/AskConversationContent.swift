import SwiftUI
import BloomCore

/// A project-free conversation in the main detail column.
struct AskConversationContent: View {
    @Environment(AppModel.self) private var app
    var sessionID: SessionID?

    init(sessionID: SessionID? = nil) {
        self.sessionID = sessionID
    }

    private var textSize: ChatTextSize { ColourThemePreference.shared.chatTextSize }
    private var chatFontID: String { ColourThemePreference.shared.chatFont }
    private var lineHeight: ChatLineHeight { ColourThemePreference.shared.chatLineHeight }

    var body: some View {
        @Bindable var ask = app.ask
        Group {
            if let trouble = app.ask.trouble {
                EmptyStateView(
                    glyph: "exclamationmark.triangle",
                    title: "This conversation has nowhere to run",
                    message: trouble
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let transcript = displayedTranscript {
                AskConversationView(transcript: transcript)
                    .id(transcript.session.id)
            } else {
                // The moment between the pane opening and the store answering. Nothing is drawn
                // rather than an empty state, because an empty state that appears for one frame
                // and is replaced reads as a fault.
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.fontScale, textSize.scale)
        .environment(\.chatFont, ChatFont(rawValue: chatFontID))
        .environment(\.chatLineHeight, lineHeight)
        // Not in a body: `open()` writes observed state and can create a session row.
        .task(id: sessionID) {
            await app.ask.open()
            if let sessionID { await app.ask.select(sessionID) }
        }
        // A popover rather than a sheet over the window, like the app's other destructive
        // questions. It hangs off the conversation rather than a control, because archive can
        // be requested from the model while a turn is still running.
        .popover(isPresented: $ask.closingID.isPresent(), arrowEdge: .top) {
            ConfirmationPopover(
                title: "Stop and archive this conversation?",
                confirmLabel: "Stop and Archive",
                tint: Palette.negative,
                onConfirm: {
                    // Read before clearing: clearing is what dismisses the popover.
                    if let id = ask.closingID { Task { await ask.close(id) } }
                    ask.closingID = nil
                },
                onCancel: { ask.closingID = nil }
            ) {
                Text("The agent will stop. The conversation will be archived.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var displayedTranscript: TranscriptModel? {
        if let sessionID { return app.ask.transcript(for: sessionID) }
        return app.ask.transcript
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
        .overlay { FileDropChatCue(sessionKey: transcript.session.id.rawValue) }
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
        message: AskConversation.emptyDetail,
        suggestionsHeading: AskConversation.suggestionsHeading,
        suggestions: AskConversation.suggestions
    )
}
