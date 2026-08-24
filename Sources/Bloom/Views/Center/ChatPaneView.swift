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
    @Bindable var model: WorkspaceModel

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
    /// every pixel of a window or sidebar drag, which is once a frame, and every one of those
    /// changes re-ran this body: the whole transcript subtree and the composer under it, rebuilt to
    /// move a clamp by one point. See `PaneMeasure`, and `TranscriptGeometry` for the same decision
    /// taken for the same reason one view down.
    @State private var conversationHeight: CGFloat = 0

    /// The conversation's text size, applied here because this pane is exactly what the setting is
    /// scoped to: what was said and what you are about to say. The sidebar, the inspector and the
    /// toolbar are chrome and keep the size macOS gives them.
    @AppStorage(ChatTextSize.defaultsKey) private var textSize = ChatTextSize.standard
    /// And the face, scoped to exactly the same subtree for exactly the same reason.
    @AppStorage(ChatFont.defaultsKey) private var chatFont = ChatFont.standard

    var body: some View {
        VStack(spacing: 0) {
            TranscriptView(
                transcript: transcript,
                isRunningSetup: model.isRunningSetup
            ) { isTranscriptScrolledUp = $0 }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // On the transcript, not on the composer, and that is the whole of the change.
            //
            // The pill is a claim about the transcript ("there is more of this below, come and
            // see"), so it belongs inside the surface it is talking about. Hung off the top of the
            // composer it straddled the rule between the two and sat half over the editor, which
            // read as a control that had something to do with what you were typing.
            //
            // It cannot cover the thing it is offering to take you to. It is only ever drawn while
            // the reader is away from the live end, and the newest row, the echo of a message on
            // its way out and any queued bubble are all below the viewport in exactly that state.
            // A short conversation is at its end by definition, so nothing is drawn over it at all.
            //
            // A gutter of clearance rather than centred on the boundary, so there is daylight
            // between the pill and `ComposerResizeHandle`'s hairline underneath it.
            .overlay(alignment: .bottom) {
                if isTranscriptScrolledUp {
                    JumpToNewestPill(action: transcript.jumpToLiveEnd)
                        .padding(.bottom, Metrics.gutter)
                }
            }

            ComposerView(
                transcript: transcript,
                model: model,
                availableHeight: conversationHeight
            )
        }
        // Rounded inside the probe rather than after it, because `onGeometryChange` only calls
        // the action when the value it is given has changed. Rounding here is what stops the
        // action running at all for the frames that do not cross a step.
        .onGeometryChange(for: CGFloat.self) { PaneMeasure.room($0.size.height) } action: {
            conversationHeight = $0
        }
        .background(Palette.windowBackground)
        .environment(\.fontScale, textSize.scale)
        .environment(\.chatFont, chatFont)
    }
}
