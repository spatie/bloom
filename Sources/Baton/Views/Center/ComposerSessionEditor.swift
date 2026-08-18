import Foundation
import BatonCore

/// Writes a session edit through to the store, and into the workspace's own copy so the tab strip
/// and the inspector do not keep showing the value from before the change.
///
/// A small type rather than a method on the view, because both the footer's pickers and the
/// composer's first-open preparation need it and neither owns the other.
@MainActor
struct ComposerSessionEditor {
    var transcript: TranscriptModel
    /// Optional so the composer can be dropped anywhere a transcript exists. When it is passed,
    /// the session list is kept in step with edits made here.
    var model: WorkspaceModel?

    func apply(_ change: (inout Session) -> Void) {
        var session = transcript.session
        change(&session)
        session.updatedAt = Date.now
        transcript.session = session

        if let model, let index = model.sessions.firstIndex(where: { $0.id == session.id }) {
            model.sessions[index] = session
        }
        // Only the columns this view owns are written. A whole-row upsert here would race the
        // agent runner, which writes the agent session id, the state and the token counters on the
        // same row, and the losing write silently breaks resume.
        Task {
            await transcript.updatePreferences(
                title: session.title,
                model: session.model,
                effort: session.effort,
                permissionMode: session.permissionMode
            )
        }
    }
}
