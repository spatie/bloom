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

    /// Attaches everything that was dropped, picked or pasted, and returns what could not be.
    ///
    /// The whole batch is attempted rather than stopping at the first failure: dragging eight
    /// screenshots and one enormous video in should attach the eight. The failures come back as
    /// sentences for the caller to put in front of the user, because a file that silently did not
    /// arrive is indistinguishable from a bug.
    @discardableResult
    func add(
        _ sources: [AttachmentSource], sessionID: String, workspace: String
    ) async -> [String] {
        var known = Set(attachments(for: sessionID).map(\.source).filter { !$0.isEmpty })
        var wanted: [AttachmentSource] = []

        for source in sources {
            // The same file dropped twice is one attachment. Checked before any copying, so a
            // second drop of a two hundred megabyte file costs nothing at all.
            if case .file(let url) = source {
                let path = url.standardizedFileURL.path
                guard known.insert(path).inserted else { continue }
            }
            wanted.append(source)
        }
        guard !wanted.isEmpty else { return [] }

        let result = await Task.detached(priority: .userInitiated) {
            var made: [PromptAttachment] = []
            var failures: [String] = []
            for source in wanted {
                do {
                    made.append(try AttachmentFiles.attach(source, workspace: workspace))
                } catch {
                    failures.append(error.readableMessage)
                }
            }
            return (made, failures)
        }.value

        guard !result.0.isEmpty else { return result.1 }
        apply(attachments(for: sessionID) + result.0, to: sessionID)
        return result.1
    }

    /// Takes one chip off. A copy Bloom made goes with it, because nothing has been sent yet and
    /// leaving it behind would put a file in the worktree that nothing on screen mentions.
    func remove(_ attachment: PromptAttachment, sessionID: String, workspace: String) {
        apply(attachments(for: sessionID).filter { $0.id != attachment.id }, to: sessionID)
        Task.detached(priority: .utility) {
            AttachmentFiles.discard(attachment, workspace: workspace)
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
