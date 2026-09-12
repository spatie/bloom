import SwiftUI
import BloomCore

/// One conversation, filling one pane of the centre column: what was said, and what you are about
/// to say.
///
/// The transcript and the composer are handed a transcript rather than reaching for one, because
/// two panes can hold two different conversations at once and neither of them is "the" session any
/// more. Everything the pair share is measured here, which is also per pane: the divider between
/// them can be dragged to a different place in each.
struct ChatPaneView: View {
    var transcript: TranscriptModel
    var model: WorkspaceModel?
    /// Which pane of the tab this is, and the only thing it is used for is remembering where the
    /// reader had got to in the conversation. See `TranscriptPaneMemory`.
    var pane: String
    var paneModel: (any WorkspacePaneModel)?

    /// Whether the user has scrolled away from the newest row, which is the only thing the jump
    /// pill is an answer to. Read here rather than passed on, because the pill is drawn here.
    ///
    /// False to start with, and that is the fix rather than a default. It used to be true, and the
    /// transcript only reports a CHANGE of position, so a pane that opened on the live end (which
    /// every pane does) was never told anything and sat on the initial value for the rest of the
    /// launch. The pill was therefore drawn over a conversation the user was watching the end of.
    /// `TranscriptListView` now also says so on arriving at a session, so the two cannot drift.
    @State private var isTranscriptScrolledUp = false

    /// What the transcript and the composer were given between them, which is what caps how far
    /// the divider between the two can be dragged.
    ///
    /// Rounded, and that is a performance decision rather than a tidiness one. Raw, it changed on
    /// every pixel of a window or sidebar drag, which is once a frame. See `PaneMeasure`, and
    /// `TranscriptGeometry` for the same decision taken for the same reason one view down.
    ///
    /// An object rather than `@State`, which is the other half of the same fix: rounding cut how
    /// OFTEN this body was re-run, and holding the number where only the composer reads it cuts
    /// what a re-run costs to nothing at all. The transcript is rebuilt by neither now. See
    /// `ComposerRoom`.
    @State private var room = ComposerRoom()
    @State private var sideOrigin: SideConversation.Snapshot?

    /// The conversation's text size, applied here because this pane is exactly what the setting is
    /// scoped to: what was said and what you are about to say. The sidebar, the inspector and the
    /// toolbar are chrome and keep the size macOS gives them.
    @AppStorage(ChatTextSize.defaultsKey) private var textSize = ChatTextSize.defaultChoice
    /// And the face, scoped to exactly the same subtree for exactly the same reason.
    @AppStorage(ChatFont.defaultsKey) private var chatFontID = ChatFont.standardID
    /// And the line height, which is the third thing the appearance pane moves about the
    /// conversation and is scoped with the other two.
    @AppStorage(ChatLineHeight.defaultsKey) private var lineHeight = ChatLineHeight.defaultChoice

    /// What the transcript has nothing to draw for, and nil the moment its rows are on screen.
    ///
    /// Here rather than in `CenterPaneView`, which owns the pane's other waits, because this one
    /// belongs to the transcript and not to the pane: while a conversation is being read the
    /// composer underneath is already drawn and already usable, so it is not part of what is
    /// missing. Hung off the pane, the spinner was centred in the transcript and the composer
    /// together and therefore sat half the composer's height below the middle of the transcript,
    /// which is 174 points low with the divider dragged out to 348, and it moved on every drag of
    /// that divider. Centred in the transcript it is a relationship to the pane rather than a
    /// distance from an edge, so dragging the divider cannot move it off the middle again.
    private var waiting: PaneWait? {
        transcript.isLoaded ? nil : .conversation(transcript.session.id)
    }

    var body: some View {
        TranscriptView(
            transcript: transcript,
            isRunningSetup: model?.isRunningSetup ?? false,
            memory: (paneModel ?? model).map { TranscriptPaneMemory(model: $0, pane: pane) }
        ) { isTranscriptScrolledUp = $0 }
        .environment(\.composerRoom, room)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            SlowLoadingView(subject: waiting, label: waiting?.label)
                .padding(.bottom, room.clearance)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            ComposerDock(
                showsJumpToNewest: isTranscriptScrolledUp,
                onJumpToNewest: transcript.jumpToLiveEnd
            ) {
                ComposerView(transcript: transcript, model: model, room: room)
            }
        }
        .overlay(alignment: .topLeading) {
            if let model, let origin = sideOrigin, transcript.session.sideConversationParentID == nil {
                Button {
                    model.paneStores.tabs.reveal(.chat(origin.parentID), in: model)
                } label: {
                    Label("From \(origin.title)", systemImage: "arrow.turn.up.left")
                        .font(.caption)
                        .padding(8)
                        .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(!model.sessions.contains { $0.id == origin.parentID })
                .padding(8)
            }
        }
        .overlay {
            if let model, let state = model.sideConversations[transcript.session.id], state.isVisible {
                GeometryReader { geometry in
                    let bottom = geometry.size.height - room.clearance >= 360 ? room.clearance + 8 : 8
                    SideConversationView(parent: transcript, state: state, model: model)
                        .frame(
                            width: max(0, min(560, geometry.size.width - 24)),
                            height: max(0, min(520, geometry.size.height - bottom - 12))
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(.trailing, 12)
                        .padding(.bottom, bottom)
                }
            }
        }
        .task(id: transcript.session.id) {
            sideOrigin = nil
            guard let model else { return }
            let origin = try? await model.store?.sideConversationSnapshot(sessionID: transcript.session.id)
            guard !Task.isCancelled else { return }
            sideOrigin = origin
        }
        .onGeometryChange(for: CGFloat.self) { PaneMeasure.room($0.size.height) } action: {
            room.height = $0
        }
        .background(Palette.windowBackground)
        .environment(\.fontScale, textSize.scale)
        .environment(\.chatFont, ChatFont(rawValue: chatFontID))
        .environment(\.chatLineHeight, lineHeight)
    }
}
