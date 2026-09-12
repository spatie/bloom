import Foundation
import BloomCore

@MainActor
enum TerminalExcerptHandoff {
    static func attach(_ excerpt: TerminalExcerpt, to model: some WorkspacePaneModel, sessionID: SessionID) async -> String? {
        guard excerpt.workspaceID == model.workspace.id else {
            return "This terminal belongs to another workspace."
        }
        model.prepareTranscript(for: sessionID)
        guard let transcript = model.existingTranscript(for: sessionID) else {
            return "The conversation for this selection has been closed."
        }
        await transcript.load()
        do {
            let outcome = await ComposerHandoff.attach(
                [.text(try excerpt.attachmentText(), named: excerpt.filename)],
                to: model, sessionID: sessionID
            )
            // The conversation may not have had a composer on screen to schedule its usual
            // debounced save. Persist before reporting success to the terminal action.
            if outcome.failure == nil, let transcript = model.existingTranscript(for: sessionID) {
                await transcript.saveDraft()
            }
            return outcome.failure
        } catch {
            return "Could not attach the terminal selection: \(error.localizedDescription)"
        }
    }
}
