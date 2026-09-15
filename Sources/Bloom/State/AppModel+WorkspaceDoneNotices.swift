import Foundation
import BloomCore

/// The app's half of `notify_when_done`: noticing that a watched workspace's turn has come to rest,
/// and putting the notice in the chat that asked.
///
/// Which ending counts, whether a watch is spent, and what the notice says are all
/// `WorkspaceDoneWatch.verdict` in the core. What is here is what only the window has: the moment
/// a turn ends, which `TranscriptModel` reports from the same places it reports to an
/// orchestrator, and the queue of the chat the notice goes into.
extension AppModel {
    /// A turn in a workspace's chat has come to rest, or is blocked on the owner.
    ///
    /// A workspace being archived is ignored here and told by `noteWorkspaceArchivedForWatchers`
    /// instead: archiving stops the agents first, and that stop arriving as "the owner stopped it"
    /// would spend the watch on the wrong sentence a second before the right one.
    func noteWorkspaceTurnEnded(_ ending: WorkspaceTurnEnding, in session: Session) async {
        guard let workspaceID = session.workspaceID, !isArchiving(workspaceID) else { return }
        await settleWorkspaceDoneWatches(
            on: workspaceID, ending: ending, sessionID: session.id,
            isSubagentChat: session.parentSessionID != nil
        )
    }

    /// Every chat waiting on this workspace is told it has gone, whatever it was waiting on.
    func noteWorkspaceArchivedForWatchers(_ workspaceID: WorkspaceID) async {
        await settleWorkspaceDoneWatches(on: workspaceID, ending: .archived, sessionID: nil, isSubagentChat: false)
    }

    private func settleWorkspaceDoneWatches(
        on workspaceID: WorkspaceID, ending: WorkspaceTurnEnding, sessionID: SessionID?, isSubagentChat: Bool
    ) async {
        guard let store,
              let watches = try? await store.unspentWorkspaceDoneWatches(targetWorkspaceID: workspaceID),
              !watches.isEmpty
        else { return }

        for watch in watches {
            switch watch.verdict(on: ending, in: sessionID, isSubagentChat: isSubagentChat) {
            case .ignore:
                continue
            case .discard:
                _ = try? await store.claimWorkspaceDoneWatch(id: watch.id)
            case .notify(let notice):
                // Claimed before anything is read, so a second ending arriving while this one
                // waits on the store finds the watch spent rather than telling the chat twice.
                guard (try? await store.claimWorkspaceDoneWatch(id: watch.id)) == true else { continue }
                await deliverWorkspaceDoneNotice(notice, to: watch)
            }
        }
    }

    /// Into the chat that asked, unless it has been closed or its workspace archived since. A
    /// notice into a closed chat would start a turn in a conversation nobody can see, which is the
    /// bug `reportToOrchestrator` names; the watch is spent either way.
    private func deliverWorkspaceDoneNotice(_ notice: CrewMessage, to watch: WorkspaceDoneWatch) async {
        guard let store,
              let chat = try? await store.session(id: watch.watcherSessionID), chat.archivedAt == nil,
              let watcherWorkspaceID = chat.workspaceID,
              let watcherWorkspace = workspaces.first(where: { $0.id == watcherWorkspaceID })
        else { return }

        _ = try? await store.enqueueDelivery(
            Delivery(
                targetSessionID: chat.id,
                sourceWorkspaceID: watch.target.workspaceID,
                kind: .report,
                crew: notice
            )
        )
        let transcript = model(for: watcherWorkspace).transcript(for: chat)
        await transcript.refreshQueue()
        await transcript.drain()
    }
}
