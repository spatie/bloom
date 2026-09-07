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
/// **One thing the strip carried was not about a worktree, and this pane had lost it with the
/// rest.** The rule under a tab strip is where the window says an agent is working, so a chat with
/// no strip said nothing while its turn ran. It is on this pane's top edge now; see the overlay in
/// `body`.
///
/// What it is is `ChatPaneView` with the workspace taken out, and it is a separate view rather than
/// that one made optional: `ChatPaneView` measures its own room, remembers its scroll position in a
/// workspace model and hangs a jump pill off a transcript that has a setup script above it. Two of
/// those three have nothing to be about here.
struct AskView: View {
    @Environment(AppModel.self) private var app

    @State private var isTranscriptScrolledUp = false
    @State private var room = ComposerRoom()

    @AppStorage(ChatTextSize.defaultsKey) private var textSize = ChatTextSize.defaultChoice
    @AppStorage(ChatFont.defaultsKey) private var chatFontID = ChatFont.standardID
    @AppStorage(ChatLineHeight.defaultsKey) private var lineHeight = ChatLineHeight.defaultChoice

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
        // The window's busy signal, on the one edge this pane has to put it on.
        //
        // Every other chat says "an agent is working" on the rule that closes off its tab strip,
        // and this pane has no strip. `ActivityRule` was already written for this conversation:
        // its `isRunning` answers `SidebarSelection.ask` with `app.ask.isRunning` rather than
        // reading `runningWorkspaceIDs`, which a chat scoped to no worktree is never in. But the
        // only thing that mounts an `ActivityRule` is `Theme.tabStripMaterial`, reached from
        // `SessionTabsView`, so with Ask selected there was no rule anywhere in the window and
        // that branch was never evaluated. The signal was written and never drawn.
        //
        // The pane's own top edge is where it goes, because that is the boundary the strip's rule
        // marks in a workspace: chrome above it, conversation below. Nothing else in this pane is
        // that boundary, and the sidebar row's mark, which does light, is behind the reader rather
        // than in front of them once Ask is the thing being looked at.
        //
        // An overlay rather than a row in the stack, so a turn starting does not shorten the
        // transcript by three points and nothing here can ask it to lay out again.
        // `ActivityRule` fades itself in and out, takes its phase from the shared `BusyPulse` so
        // it moves in step with every lit mark in the window, and draws `StillActivityRule` under
        // Reduce Motion. All three are settled by using it rather than by drawing a second figure.
        //
        // No accessibility label on it: the transcript's own `StreamingStatusView` already says
        // "Working", and the same fact announced twice is noise.
        .overlay(alignment: .top) {
            ActivityRule()
                .frame(height: BusyCrest.thickness)
        }
        .environment(\.fontScale, textSize.scale)
        .environment(\.chatFont, ChatFont(rawValue: chatFontID))
        .environment(\.chatLineHeight, lineHeight)
        // Not in a body: `open()` writes observed state and can create a session row.
        .task { await app.ask.open() }
    }

    private func conversation(_ transcript: TranscriptModel) -> some View {
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
