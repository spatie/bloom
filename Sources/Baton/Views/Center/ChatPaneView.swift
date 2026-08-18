import SwiftUI
import BatonCore

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

    /// The transcript reports whether the user has scrolled away from the newest row. Until it
    /// does, the unread pill is offered whenever there is anything unread.
    @State private var isTranscriptScrolledUp = true

    /// What the transcript and the composer were given between them, which is what caps how far
    /// the divider between the two can be dragged.
    @State private var conversationHeight: CGFloat = 0

    /// The conversation's text size, applied here because this pane is exactly what the setting is
    /// scoped to: what was said and what you are about to say. The sidebar, the inspector and the
    /// toolbar are chrome and keep the size macOS gives them.
    @AppStorage(ChatTextSize.defaultsKey) private var textSize = ChatTextSize.standard

    var body: some View {
        VStack(spacing: 0) {
            TranscriptView(
                transcript: transcript,
                isRunningSetup: model.isRunningSetup
            ) { isTranscriptScrolledUp = $0 }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            ComposerView(
                transcript: transcript,
                model: model,
                isScrolledUp: isTranscriptScrolledUp,
                availableHeight: conversationHeight
            )
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
            conversationHeight = $0
        }
        .background(Palette.windowBackground)
        .environment(\.fontScale, textSize.scale)
    }
}
