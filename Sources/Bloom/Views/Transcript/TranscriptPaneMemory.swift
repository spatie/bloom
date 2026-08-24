import BloomCore

/// The one pane's worth of `WorkspaceModel.panePositions` a transcript list is allowed to read and
/// write.
///
/// A pass-through rather than a store of its own, and it exists so that the list does not have to
/// be handed a whole `WorkspaceModel` to remember where it was. Two views between the pane and the
/// list would then be carrying a model neither of them draws anything from, and a `@Bindable` one
/// at that.
///
/// The pane id is half the key because a split tab can hold the same conversation twice, each half
/// scrolled somewhere else, and `CenterPanesView.soloPane` means an unsplit tab's pane answers to
/// the same name in every workspace and every tab. See `TranscriptPaneState.Key`.
///
/// Nil for a transcript nobody can scroll back to: the archive sheet draws one and is gone.
@MainActor
struct TranscriptPaneMemory {
    let model: WorkspaceModel
    let pane: String

    func remembered(session: SessionID) -> TranscriptPaneState? {
        model.panePosition(pane: pane, session: session)
    }

    func remember(_ state: TranscriptPaneState, session: SessionID) {
        model.rememberPanePosition(state, pane: pane, session: session)
    }
}
