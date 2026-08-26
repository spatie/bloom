import SwiftUI
import BloomCore

/// Ask Bloom: one conversation, filling the centre column, scoped to no workspace.
///
/// **No furniture that assumes a worktree.** There is no tab strip, because there is one chat; no
/// inspector, because there is no diff; no terminal, because there is nowhere to run anything; and
/// no pull request accessory in the title bar, because there is no branch. All of that falls out of
/// `SidebarSelection.ask` having a nil `workspaceID` rather than being hidden here one control at a
/// time.
///
/// What it is is `ChatPaneView` with the workspace taken out, and it is a separate view rather than
/// that one made optional: `ChatPaneView` measures its own room, remembers its scroll position in a
/// workspace model and hangs a jump pill off a transcript that has a setup script above it. Two of
/// those three have nothing to be about here.
struct AskView: View {
    @Environment(AppModel.self) private var app

    @State private var isTranscriptScrolledUp = false
    @State private var room = ComposerRoom()

    @AppStorage(ChatTextSize.defaultsKey) private var textSize = ChatTextSize.standard
    @AppStorage(ChatFont.defaultsKey) private var chatFont = ChatFont.standard

    var body: some View {
        VStack(spacing: 0) {
            if let trouble = app.ask.trouble {
                EmptyStateView(
                    glyph: "exclamationmark.triangle",
                    title: "This conversation has nowhere to run",
                    message: trouble
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let transcript = app.ask.transcript {
                conversation(transcript)
            } else {
                // The moment between the pane opening and the store answering. Nothing is drawn
                // rather than an empty state, because an empty state that appears for one frame
                // and is replaced reads as a fault.
                Color.clear
            }
        }
        .background(Palette.windowBackground)
        .environment(\.fontScale, textSize.scale)
        .environment(\.chatFont, chatFont)
        // Not in a body: `open()` writes observed state and can create a session row.
        .task { await app.ask.open() }
    }

    private func conversation(_ transcript: TranscriptModel) -> some View {
        VStack(spacing: 0) {
            ZStack {
                TranscriptView(transcript: transcript) { isTranscriptScrolledUp = $0 }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Over the transcript rather than in place of it, because the transcript is what
                // fills as soon as anything is said and the pane must not change shape underneath
                // the first answer. It goes the moment there is a bubble, a sentence on its way
                // out or one queued: see `hasNothingToShow`.
                if transcript.hasNothingToShow {
                    opening
                }
            }
            .overlay(alignment: .bottom) {
                if isTranscriptScrolledUp {
                    JumpToNewestPill(action: transcript.jumpToLiveEnd)
                        .padding(.bottom, Metrics.gutter)
                }
            }

            // No workspace model, which the composer already allows for: its `model` is optional
            // so that it can be dropped anywhere a transcript exists. What it loses here is the
            // review comments and the worktree an attachment is resolved against, neither of which
            // this chat has.
            ComposerView(transcript: transcript, model: nil, room: room)
        }
        // The height the two share, which is what caps how far the divider between them can be
        // dragged. Rounded inside the probe for the reason `ChatPaneView` gives: raw, it changed on
        // every pixel of a window drag.
        .onGeometryChange(for: CGFloat.self) { PaneMeasure.room($0.size.height) } action: {
            room.height = $0
        }
    }

    /// What the owner sees the first time they open it, and after starting a fresh one.
    ///
    /// It says what this chat can do and what it cannot, in that order, because the second is the
    /// surprising half: it looks exactly like every other conversation in Bloom and it cannot
    /// change a file.
    private var opening: some View {
        EmptyStateView(
            glyph: "bubble.left.and.text.bubble.right",
            title: AskConversation.emptyHeading,
            message: AskConversation.emptyDetail
        )
    }
}
