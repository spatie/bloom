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
        workspace: String,
        undo: UndoManager? = nil
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
        register(result.made, from: wanted, sessionID: sessionID, workspace: workspace, undo: undo)
        return result
    }

    /// Command+Z after a paste, because pasting is an edit and an edit that cannot be undone is
    /// the one kind users learn to be careful around.
    ///
    /// Registered with the window's undo manager, which is the same object the composer's text
    /// view is already registering its typing with, so one stack holds both in the order they
    /// happened: undo after pasting a screenshot takes the chip back off, and undo again takes
    /// back the word typed before it.
    ///
    /// Undoing removes the chip and the copy exactly as the chip's own remove control does, and
    /// registering from inside an undo is what makes the next step the redo. Redo attaches the
    /// same clipboard bytes and the same files again, under fresh ids, which is why the sources
    /// are carried rather than the paths: the bytes a screenshot arrived as no longer exist
    /// anywhere else by then, and the clipboard has usually moved on.
    private func register(
        _ made: [PromptAttachment],
        from sources: [AttachmentSource],
        sessionID: String,
        workspace: String,
        undo: UndoManager?
    ) {
        guard let undo, !made.isEmpty else { return }

        undo.registerUndo(withTarget: self) { [weak undo] store in
            MainActor.assumeIsolated {
                store.remove(made, sessionID: sessionID, workspace: workspace)
                guard let undo else { return }
                undo.registerUndo(withTarget: store) { [weak undo] store in
                    MainActor.assumeIsolated {
                        store.reattach(
                            sources, sessionID: sessionID, workspace: workspace, undo: undo
                        )
                    }
                }
            }
        }
        undo.setActionName(actionName(for: made))
    }

    /// Redo, which is an undo of an undo: the same bytes and the same files attached again, which
    /// registers its own undo on the way and puts the pair back on the stack.
    private func reattach(
        _ sources: [AttachmentSource], sessionID: String, workspace: String, undo: UndoManager?
    ) {
        Task {
            _ = await add(sources, sessionID: sessionID, workspace: workspace, undo: undo)
        }
    }

    private func actionName(for made: [PromptAttachment]) -> String {
        // What the Edit menu says after "Undo". Deliberately the same word for every door: the
        // paperclip, a drag and the clipboard all end in a chip, and the chip is what goes away.
        return made.count == 1 ? "Attach" : "Attach \(made.count) Files"
    }

    /// Takes one chip off. A copy Bloom made goes with it, because nothing has been sent yet and
    /// leaving it behind would put a file in the worktree that nothing on screen mentions.
    func remove(_ attachment: PromptAttachment, sessionID: String, workspace: String) {
        remove([attachment], sessionID: sessionID, workspace: workspace)
    }

    /// The same, for the whole of one batch at once, which is what undoing a paste of three
    /// screenshots has to take back.
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

    /// Called once the turn has gone. The chips go, the files stay: the prompt the agent is
    /// reading names those paths, and deleting them out from under it would break the one thing
    /// the attachment was for.
    func clear(sessionID: String) {
        apply([], to: sessionID)
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
