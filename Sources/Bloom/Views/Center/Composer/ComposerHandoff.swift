import SwiftUI
import BloomCore

/// The one route from somewhere else in the window into the composer's next prompt.
///
/// A browser pane and the checks list both have the same problem: they are showing something the
/// agent should see, and they are nowhere near the box you would type it into. Both used to end in
/// the user taking a screenshot by hand or selecting a log and copying it. This is what a button in
/// either of them calls, and it is deliberately the same door the paperclip and a drag already go
/// through, `PromptAttachmentStore.add`, so a file that arrives this way is a file in every respect
/// the composer already knows about: it is copied under `.bloom/attachments`, it is a chip, it is
/// undoable, it is removed if the sentence stops naming it, and it survives a relaunch.
///
/// It is not a view and it does not draw. The button that calls it is the view's whole share.
@MainActor
enum ComposerHandoff {
    /// What came of it: nothing to report, or a sentence to put in front of the user.
    ///
    /// A failure has to be spoken. Something that quietly did not arrive in the composer is
    /// indistinguishable from a button that does nothing, and this is a button whose entire
    /// promise is that the file is now in the prompt.
    struct Outcome: Sendable {
        var failure: String?
    }

    /// Attaches to the workspace's active session, writes `body` at the end of that draft, and
    /// brings the conversation into view.
    ///
    /// **At the end of the draft rather than at the caret**, which is the one place this differs
    /// from a drop. A drop knows where it was let go; a button in another pane does not, and the
    /// caret it would find is wherever the user last left it, which is as likely to be the middle
    /// of a word as anywhere. The end is the only position that is the same every time.
    ///
    /// **The conversation is revealed rather than switched to.** `WorkspaceTabsStore.reveal` does
    /// nothing at all when the chat is already a pane of the tab on screen, which is the split the
    /// browser is normally used in, so a snapshot taken beside the composer does not throw the
    /// browser away to show a box that was never hidden. It is only when the pane is filling the
    /// window that the tab changes, and then it has to: an attachment you cannot see did not
    /// visibly happen.
    @discardableResult
    static func attach(
        _ sources: [AttachmentSource],
        to model: WorkspaceModel,
        body: @escaping @Sendable ([String]) -> String = { $0.map(AttachmentDraft.token(for:)).joined(separator: " ") }
    ) async -> Outcome {
        guard let session = model.activeSession else {
            return Outcome(failure: "This workspace has no conversation to attach to yet.")
        }
        model.prepareTranscript(for: session.id)
        guard let transcript = model.existingTranscript(for: session.id) else {
            return Outcome(failure: "This workspace's conversation could not be opened.")
        }

        let key = session.id.rawValue
        let store = PromptAttachmentStore.shared
        store.load(sessionID: key)

        let added = await store.add(sources, sessionID: key, workspace: model.workspace.path)
        guard !added.paths.isEmpty else {
            return Outcome(failure: added.failures.first ?? "Nothing could be attached.")
        }

        append(body(added.paths), to: transcript)
        WorkspaceTabsStore.shared.reveal(.chat(session.id), in: model)

        return Outcome(failure: added.failures.first)
    }

    /// A sentence with nothing attached to it, put in the same place by the same rules.
    ///
    /// The case a failed check falls into when its log could not be fetched: the name, the
    /// conclusion and the URL are worth handing over on their own, and going through the
    /// attachment path with no files would only produce a failure to report.
    @discardableResult
    static func write(_ sentence: String, to model: WorkspaceModel) async -> Outcome {
        guard let session = model.activeSession else {
            return Outcome(failure: "This workspace has no conversation to write to yet.")
        }
        model.prepareTranscript(for: session.id)
        guard let transcript = model.existingTranscript(for: session.id) else {
            return Outcome(failure: "This workspace's conversation could not be opened.")
        }
        append(sentence, to: transcript)
        WorkspaceTabsStore.shared.reveal(.chat(session.id), in: model)
        return Outcome()
    }

    /// Puts a sentence at the end of a draft, on its own line where there is already something
    /// there.
    ///
    /// A newline rather than a space, because everything that arrives this way is a sentence about
    /// a file rather than a word in one the user was writing, and running it onto the end of a
    /// half-typed thought is how the two become unreadable together.
    private static func append(_ addition: String, to transcript: TranscriptModel) {
        guard !addition.isEmpty else { return }
        let draft = transcript.draft
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            transcript.draft = addition + " "
            return
        }
        let separator = draft.hasSuffix("\n") ? "" : "\n"
        transcript.draft = draft + separator + addition + " "
    }
}
