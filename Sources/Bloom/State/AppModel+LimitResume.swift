import Foundation
import BloomCore

/// Picking up, at launch, the chats that were waiting on the allowance when Bloom last quit. What
/// is saved and whether it still applies is `SavedLimitResume`; this finds the chat and arms it.
extension AppModel {
    func restoreLimitResumes() async {
        guard let store, let settings = try? await store.settings(prefix: SavedLimitResume.keyPrefix) else { return }
        for (sessionID, saved) in SavedLimitResume.all(in: settings) {
            guard let transcript = await transcriptToResume(sessionID) else {
                try? await store.setSetting(SavedLimitResume.key(for: sessionID), nil)
                continue
            }
            transcript.continueAfterLimitResets(hitAt: saved.hitAt, notBefore: saved.notBefore)
        }
    }

    /// The chat a saved wait belongs to, while it is open, still ends on the refused turn, and has
    /// its worktree on this Mac. `make dev-db` copies the settings and points every workspace at a
    /// root that does not exist, so Bloom Dev must not continue the owner's chats.
    private func transcriptToResume(_ sessionID: SessionID) async -> TranscriptModel? {
        guard let store,
              let session = try? await store.session(id: sessionID), session.archivedAt == nil,
              LimitResume.canWatch(session.agentKind),
              let workspaceID = session.workspaceID,
              let workspace = workspaces.first(where: { $0.id == workspaceID }),
              FileManager.default.fileExists(atPath: workspace.path),
              let tail = try? await store.recentMessages(sessionID: sessionID, limit: SavedLimitResume.rowsToCheck),
              SavedLimitResume.stillApplies(walkingBack: tail.reversed().lazy.map { (kind: $0.kind, payload: $0.payload) })
        else { return nil }
        return model(for: workspace).transcript(for: session)
    }
}
