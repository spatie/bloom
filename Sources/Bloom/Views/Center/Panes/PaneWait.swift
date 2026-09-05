import BloomCore

/// What a pane with nothing to draw is waiting for.
///
/// Two of them, and they are two different moments of the same switch. Which one the user actually
/// meets depends on whether this launch has been here before, which is why neither could be left
/// out.
///
/// It has a file of its own rather than sitting inside `CenterPaneView` because the two waits are
/// drawn in two different places, and both of them need these words. A pane waiting on
/// `.sessions` has nothing in it at all, so the whole pane is what is missing and `CenterPaneView`
/// draws that one over the whole pane. `.conversation` is a transcript being read, and a pane
/// reading a transcript already has its composer on screen underneath it, so `ChatPaneView` draws
/// that one over the transcript alone. See `ChatPaneView.waiting` for what one overlay doing both
/// did to where the spinner landed.
enum PaneWait: Equatable, Sendable {
    /// The store has not yet said which conversations this workspace has. The first visit of a
    /// launch only, since `WorkspaceModel.hasReadSessions` stays true afterwards.
    case sessions(WorkspaceID)
    /// The conversation is known and its rows are not on screen yet: either this launch has never
    /// built its transcript, or the transcript exists and is still reading.
    case conversation(SessionID)

    /// In the register the file loader already uses: what is being read.
    var label: String {
        switch self {
        case .sessions: "Opening the workspace"
        case .conversation: "Reading the conversation"
        }
    }
}
