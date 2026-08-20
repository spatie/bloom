import SwiftUI
import Observation
import BloomCore

/// What every session has attached to its next prompt.
///
/// A store rather than view state, for the same reason `CenterTabStore` is one: the composer is
/// rebuilt whenever the centre column is split, a tab is switched or a pane is rearranged, and a
/// screenshot dropped a moment ago must not vanish because the view that held it was thrown away.
/// It is keyed by session, exactly like the draft it sits above.
///
/// It lives here rather than on `AppModel` because nothing outside the composer has any business
/// knowing what the next turn is carrying. The list is written to user defaults for the same
/// reason the tab list is: it is small, it is worth having after a relaunch, and it is cheap to
/// lose. The files themselves are in the worktree and outlive it either way.
@MainActor
@Observable
final class PromptAttachmentStore {
    static let shared = PromptAttachmentStore()

    private(set) var bySession: [String: [PromptAttachment]] = [:]

    private init() {}

    // MARK: - Reading

    func attachments(for sessionID: String) -> [PromptAttachment] {
        bySession[sessionID] ?? []
    }

    /// Reads a session's attachments back once per launch. Called from a task rather than from a
    /// getter, because filling the map is a mutation and a view body may not cause one.
    func load(sessionID: String) {
        guard bySession[sessionID] == nil else { return }
        bySession[sessionID] = Self.restore(sessionID: sessionID)
    }

    // MARK: - Writing

    /// What one batch of attaching came to: the chips it put up, and the sentences for the ones
    /// it could not.
    struct Added: Sendable {
        var made: [PromptAttachment] = []
        /// Failures, as sentences to put in front of the user. A file that silently did not
        /// arrive is indistinguishable from a bug.
        var failures: [String] = []
    }

    /// Attaches everything that was dropped, picked or pasted, and says what came of it.
    ///
    /// The whole batch is attempted rather than stopping at the first failure: dragging eight
    /// screenshots and one enormous video in should attach the eight.
    @discardableResult
    func add(
        _ sources: [AttachmentSource],
        sessionID: String,
        workspace: String
    ) async -> Added {
        let existing = attachments(for: sessionID)
        var known = Set(existing.map(\.source).filter { !$0.isEmpty })
        // Names already spoken for, so a second screenshot pasted inside the same second is not a
        // second chip reading exactly like the first. They cannot collide on disk, because every
        // attachment is written into its own six character folder, but two chips nobody can tell
        // apart is the same problem one step further on.
        var taken = Set(existing.map(\.filename))
        var wanted: [AttachmentSource] = []

        for source in sources {
            // The same file dropped twice is one attachment. Checked before any copying, so a
            // second drop of a two hundred megabyte file costs nothing at all.
            if case .file(let url) = source {
                let path = url.standardizedFileURL.path
                guard known.insert(path).inserted else { continue }
                taken.insert(url.lastPathComponent)
                wanted.append(source)
                continue
            }
            let name = PastedAttachment.uniqued(source.filename, avoiding: taken)
            taken.insert(name)
            wanted.append(source.named(name))
        }
        guard !wanted.isEmpty else { return Added() }

        let result = await Task.detached(priority: .userInitiated) {
            var added = Added()
            for source in wanted {
                do {
                    added.made.append(try AttachmentFiles.attach(source, workspace: workspace))
                } catch {
                    added.failures.append(error.readableMessage)
                }
            }
            return added
        }.value

        guard !result.made.isEmpty else { return result }
        apply(attachments(for: sessionID) + result.made, to: sessionID)
        return result
    }

    /// Why there is no undo registered here any more.
    ///
    /// A file is a word in the draft now, so attaching one is an edit to the text and the text
    /// system's own undo is what takes it back: `ComposerEditorHandle` makes the insertion through
    /// the text view, which puts it on the same stack as the words typed either side of it, in
    /// order. What is left here is the copy on disk, and that deliberately outlives an undo. It
    /// stays until the turn is sent, when whatever the sentence no longer names is discarded, so
    /// undoing an attachment and redoing it finds the same file under the same path rather than a
    /// second copy under a new one.

    /// Takes one file off. A copy Bloom made goes with it, because nothing has been sent yet and
    /// leaving it behind would put a file in the worktree that nothing on screen mentions.
    func remove(_ attachment: PromptAttachment, sessionID: String, workspace: String) {
        remove([attachment], sessionID: sessionID, workspace: workspace)
    }

    /// The same, for a batch of them at once, which is what a turn going out has to do with the
    /// copies its sentence stopped naming.
    func remove(_ attachments: [PromptAttachment], sessionID: String, workspace: String) {
        let ids = Set(attachments.map(\.id))
        guard !ids.isEmpty else { return }
        apply(self.attachments(for: sessionID).filter { !ids.contains($0.id) }, to: sessionID)
        Task.detached(priority: .utility) {
            for attachment in attachments {
                AttachmentFiles.discard(attachment, workspace: workspace)
            }
        }
    }

    /// Called once the turn has gone. The records go, the files stay: the prompt the agent is
    /// reading names those paths, and deleting them out from under it would break the one thing
    /// the attachment was for.
    func clear(sessionID: String) {
        apply([], to: sessionID)
    }

    /// What a sent turn leaves behind, given the sentence that went with it.
    ///
    /// Every copy the message still names stays where it is, because the agent is about to read
    /// it. Every copy it does not is a file nothing refers to any more, which is what a paste that
    /// was undone, or a chip that was typed back out of the sentence, leaves in the worktree.
    /// Deleted here rather than at the moment of editing, so undo and redo of an attachment find
    /// the same file under the same path.
    func settle(sent text: String, sessionID: String, workspace: String) {
        let held = attachments(for: sessionID)
        let named = Set(AttachmentDraft.parse(text, paths: held.map(\.path)).paths)
        remove(held.filter { !named.contains($0.path) }, sessionID: sessionID, workspace: workspace)
        clear(sessionID: sessionID)
    }

    // MARK: - Persistence

    private func apply(_ attachments: [PromptAttachment], to sessionID: String) {
        bySession[sessionID] = attachments
        Self.persist(attachments, sessionID: sessionID)
    }

    private static func key(_ sessionID: String) -> String { "composer.attachments.\(sessionID)" }

    private static func persist(_ attachments: [PromptAttachment], sessionID: String) {
        let defaults = UserDefaults.standard
        guard !attachments.isEmpty else {
            defaults.removeObject(forKey: key(sessionID))
            return
        }
        guard let data = try? JSONEncoder().encode(attachments) else { return }
        defaults.set(data, forKey: key(sessionID))
    }

    private static func restore(sessionID: String) -> [PromptAttachment] {
        guard let data = UserDefaults.standard.data(forKey: key(sessionID)),
              let attachments = try? JSONDecoder().decode([PromptAttachment].self, from: data)
        else { return [] }
        return attachments
    }
}
