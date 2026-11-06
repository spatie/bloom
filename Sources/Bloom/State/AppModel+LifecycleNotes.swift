import Foundation
import BloomCore

/// Telling a workspace's chats that it was archived or restored.
///
/// The transcript is the one place somebody reading an archived workspace is already looking, so the
/// note goes there rather than into a notice that fades.

extension AppModel {

    /// Read before the archive, because afterwards the worktree is gone and a script that ran cannot
    /// be told from one that was skipped. The branch and the kept folder are filled in once the
    /// archive has settled them.
    func archiveFacts(of workspace: Workspace, in repo: Repo) -> WorkspaceLifecycleNote.ArchiveFacts {
        let settings = SettingsLoader.load(repo: repo.path)
        let launch = ScriptLaunch.resolve(
            text: settings.archiveScript, file: settings.scriptFiles[.archive], repo: repo.path
        )
        let scriptIsRunnable: Bool
        switch launch {
        case .executable, .source: scriptIsRunnable = true
        case .missing, nil: scriptIsRunnable = false
        }
        return WorkspaceLifecycleNote.ArchiveFacts(
            branch: workspace.branch,
            branchKept: true,
            ranArchiveScript: scriptIsRunnable && FileManager.default.fileExists(atPath: workspace.path),
            hasSetupScript: settings.setupScript != nil
        )
    }

    /// Appends the note to every chat somebody opened. Empty chats are left alone: a note would
    /// give them a row and keep a tab nobody used.
    ///
    /// A transcript already on screen, the archived reader's, only reads its rows once, so it is
    /// told to pick the new one up.
    func record(_ note: WorkspaceLifecycleNote, in workspaceID: WorkspaceID) async {
        guard let store, let sessions = try? await store.sessions(workspaceID: workspaceID) else { return }
        for id in TabSet.tabbable(sessions) {
            do {
                guard try await store.nextSeq(sessionID: id) > 0 else { continue }
                try await store.appendNext(sessionID: id, kind: .notice, payload: note.payload)
                await workspaceModels[workspaceID]?.existingTranscript(for: id)?.appendLatestMessages()
            } catch {
                Log.archive.error(
                    "could not note the \(note.event.rawValue, privacy: .public) workspace in a chat: \(error.readableMessage, privacy: .public)"
                )
            }
        }
    }
}
