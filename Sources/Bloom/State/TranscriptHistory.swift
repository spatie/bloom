import Foundation
import Observation
import BloomCore

/// A worktree may hold several conversations. An unresolved file/history operation blocks
/// all of their send paths, including a conversation opened after the operation started.
@MainActor
@Observable
final class HistoryWorkspaceGate {
    static let shared = HistoryWorkspaceGate()
    private(set) var held: Set<WorkspaceID> = []
    private(set) var unresolved: Set<WorkspaceID> = []
    @ObservationIgnored private var leases: [WorkspaceID: WorkspaceOperationLease] = [:]

    func holds(_ id: WorkspaceID) -> Bool { held.contains(id) || unresolved.contains(id) }
    func begin(_ id: WorkspaceID, worktree: String) -> Bool {
        guard !held.contains(id), let lease = WorkspaceOperationLease.acquire(in: worktree, operation: .rewind) else { return false }
        leases[id] = lease
        held.insert(id)
        return true
    }
    func lease(for id: WorkspaceID) -> WorkspaceOperationLease? { leases[id] }
    func end(_ id: WorkspaceID) {
        leases.removeValue(forKey: id)?.release()
        held.remove(id)
    }
    func mark(_ id: WorkspaceID, unresolved value: Bool) {
        if value { unresolved.insert(id) } else { unresolved.remove(id) }
    }
}

@MainActor
@Observable
final class TranscriptHistory {
    var checkpoints: [TurnCheckpoint] = []
    var pendingRewind: CheckpointRewind?
    var failure: String?
    var blockingSessionID: SessionID?
    private(set) var isCapturing = false
    var isFinalisingTurn = false
    private(set) var isRewinding = false
    var hasActiveTurn: Bool { active != nil }
    @ObservationIgnored private var active: TurnCheckpoint?
    @ObservationIgnored private var activeDeliveryID: DeliveryID?

    func load(store: Store, sessionID: SessionID, workspaceID: WorkspaceID?) async {
        do {
            checkpoints = try await store.turnCheckpoints(sessionID: sessionID)
            let journal = try await store.checkpointRewind(sessionID: sessionID)
            pendingRewind = journal?.stage == .complete ? nil : journal
            if let workspaceID, pendingRewind != nil {
                HistoryWorkspaceGate.shared.mark(workspaceID, unresolved: true)
            }
        } catch { failure = "Could not load turn history: \(error.localizedDescription)" }
    }

    func cleanupRetired(store: Store, sessionID: SessionID, cwd: String) async {
        do { try await TurnCheckpointStore(store: store).cleanupRetired(sessionID: sessionID, cwd: cwd) } catch { failure = "Could not finish cleaning up old snapshots: \(error)" }
    }

    func begin(delivery: Delivery, store: Store, cwd: String) async {
        isCapturing = true
        defer { isCapturing = false }
        do {
            guard let saved = try await store.delivery(id: delivery.id), let seq = saved.deliveredSeq else {
                throw SnapshotFailure("The sent message has no stored sequence.")
            }
            active = try await TurnCheckpointStore(store: store).begin(
                sessionID: delivery.targetSessionID, cwd: cwd, startSeq: seq
            )
            activeDeliveryID = delivery.id
            failure = nil
        } catch { failure = "Could not capture this turn's starting state: \(error)" }
    }

    func sent(delivery: Delivery, store: Store) async {
        do {
            guard let saved = try await store.delivery(id: delivery.id), let provider = saved.providerTurnID,
                  let seq = saved.deliveredSeq else { return }
            // Steering messages and chats without a worktree have no starting snapshot. The
            // association lives in Store; a reused sequence after rewind has no cached identity.
            guard try await store.linkTurnCheckpoint(
                sessionID: saved.targetSessionID, startSeq: seq, providerTurnID: provider
            ) else { return }
            if var current = active, current.startSeq == seq {
                current.providerTurnID = provider
                active = current
            }
            merge(try await store.turnCheckpoints(sessionID: saved.targetSessionID))
        } catch { failure = "Could not link the turn to its snapshot: \(error)" }
    }

    func finish(store: Store, cwd: String, endSeq: Int, captureFiles: Bool = true) async {
        guard let checkpoint = active else { return }
        active = nil
        isCapturing = true
        defer { isCapturing = false; activeDeliveryID = nil }
        do {
            if !captureFiles {
                var closed = checkpoint
                closed.endSeq = max(endSeq, checkpoint.startSeq)
                try await store.saveTurnCheckpoint(closed)
                merge(try await store.turnCheckpoints(sessionID: checkpoint.sessionID))
                failure = "This turn's final file snapshot is unavailable because another turn had already started."
                return
            }
            var providerTurnID = checkpoint.providerTurnID
            if let id = activeDeliveryID, let delivery = try await store.delivery(id: id) {
                providerTurnID = delivery.providerTurnID ?? providerTurnID
            }
            _ = try await TurnCheckpointStore(store: store).finish(
                id: checkpoint.id, sessionID: checkpoint.sessionID, cwd: cwd, endSeq: max(endSeq, checkpoint.startSeq),
                providerTurnID: providerTurnID
            )
            merge(try await store.turnCheckpoints(sessionID: checkpoint.sessionID))
        } catch { failure = "Could not capture this turn's final state: \(error)" }
    }

    private func merge(_ records: [TurnCheckpoint]) {
        let previous = Dictionary(checkpoints.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        checkpoints = records.map { record in
            var merged = record
            if merged.after == nil, let completed = previous[record.id], completed.after != nil {
                merged.after = completed.after
                merged.endSeq = completed.endSeq
            }
            merged.providerTurnID = merged.providerTurnID ?? previous[record.id]?.providerTurnID
            return merged
        }
    }

    func diff(_ checkpoint: TurnCheckpoint, store: Store, cwd: String, path: String? = nil) async throws -> String {
        try await TurnCheckpointStore(store: store).diff(checkpoint, cwd: cwd, path: path)
    }

    func files(_ checkpoint: TurnCheckpoint, cwd: String) async throws -> [ChangedFile] {
        guard let after = checkpoint.after else { throw SnapshotFailure("This turn has no completed snapshot.") }
        return try await Git.snapshotFiles(from: checkpoint.before, to: after, in: cwd)
    }

    func rewind(_ checkpoint: TurnCheckpoint, restoringFiles: Bool, transcript: TranscriptModel, app: AppModel) async {
        guard let workspace = transcript.workspace, let store = app.store,
              let turnID = checkpoint.providerTurnID, transcript.session.agentKind == .codex,
              !isRewinding, !HistoryWorkspaceGate.shared.holds(workspace.id),
              HistoryWorkspaceGate.shared.begin(workspace.id, worktree: transcript.cwd) else { return }
        isRewinding = true
        defer { isRewinding = false; HistoryWorkspaceGate.shared.end(workspace.id) }
        let service = TurnCheckpointStore(store: store)
        do {
            try await requireIdleWorkspace(transcript: transcript, app: app, store: store)
            guard try await store.pendingCheckpointRewind(workspaceID: workspace.id) == nil else {
                throw SnapshotFailure("Resolve the previous interrupted rewind first.")
            }
            let backup = try await store.prepareTranscriptRewind(checkpoint)
            try requireAttachments(backup.prompt, cwd: transcript.cwd)
            // Validate the provider boundary before changing files. A stale local checkpoint
            // cannot become a file restore followed by a predictable missing-turn failure.
            guard try await transcript.providerContainsTurn(turnID) else { throw ConversationRewindError.missingTurn }
            try await requireIdleWorkspace(transcript: transcript, app: app, store: store)
            var journal = try await service.prepareRewind(
                checkpoint: checkpoint, cwd: transcript.cwd, restoringFiles: restoringFiles,
                operationLease: HistoryWorkspaceGate.shared.lease(for: workspace.id)
            )
            pendingRewind = journal
            HistoryWorkspaceGate.shared.mark(workspace.id, unresolved: true)
            if restoringFiles {
                try await Git.restoreSnapshot(checkpoint.before, in: transcript.cwd)
                journal.stage = .filesRestored
                try await service.markRewind(journal)
                pendingRewind = journal
            }
            try await transcript.rewindProvider(beforeTurnID: turnID)
            journal.stage = .providerReverted
            try await service.markRewind(journal)
            pendingRewind = journal
            try await finishRewind(journal, transcript: transcript, app: app, store: store)
        } catch {
            failure = "Rewind could not finish: \(error)"
            if var journal = pendingRewind {
                journal.failure = failure
                pendingRewind = journal
                try? await service.markRewind(journal)
            }
        }
    }

    /// An unanswered request is not proof of failure. Reconcile the exact boundary before
    /// truncating local history or allowing another send, including after an app restart.
    func recover(transcript: TranscriptModel, app: AppModel) async {
        guard let journal = pendingRewind, let workspace = transcript.workspace, let store = app.store,
              let turnID = journal.checkpoint.providerTurnID,
              !isRewinding, HistoryWorkspaceGate.shared.begin(workspace.id, worktree: transcript.cwd) else { return }
        isRewinding = true
        defer { isRewinding = false; HistoryWorkspaceGate.shared.end(workspace.id) }
        do {
            try await requireIdleWorkspace(transcript: transcript, app: app, store: store)
            let reverted: Bool
            if journal.stage == .providerReverted { reverted = true } else {
                let retained = try await transcript.providerContainsTurn(turnID)
                reverted = !retained
            }
            if reverted {
                var confirmed = journal
                confirmed.stage = .providerReverted
                try await store.saveCheckpointRewind(confirmed)
                try await finishRewind(confirmed, transcript: transcript, app: app, store: store)
            } else {
                // Provider retained the turn. Put files and staging back, keeping the transcript
                // and draft intact. A provider lookup error never reaches this branch.
                if let recovery = journal.recovery { try await Git.restoreSnapshot(recovery, in: transcript.cwd) }
                var resolved = journal
                resolved.stage = .complete
                resolved.failure = nil
                try await store.saveCheckpointRewind(resolved)
                pendingRewind = nil
                failure = nil
                HistoryWorkspaceGate.shared.mark(workspace.id, unresolved: false)
            }
        } catch { failure = "Could not resolve the interrupted rewind: \(error)" }
    }

    private func finishRewind(_ journal: CheckpointRewind, transcript: TranscriptModel, app: AppModel, store: Store) async throws {
        _ = try await store.completeTranscriptRewind(sessionID: transcript.session.id)
        try await TurnCheckpointStore(store: store).removeAfter(
            sessionID: transcript.session.id, seq: journal.checkpoint.startSeq, cwd: transcript.cwd
        )
        await transcript.reloadAfterRewind()
        pendingRewind = nil
        failure = nil
        if let workspace = transcript.workspace {
            HistoryWorkspaceGate.shared.mark(workspace.id, unresolved: false)
        }
    }

    private func requireIdleWorkspace(transcript: TranscriptModel, app: AppModel, store: Store) async throws {
        guard let workspace = transcript.workspace, !app.isArchiving(workspace.id) else { throw ConversationRewindError.busy }
        let sessions = try await store.sessions(workspaceID: workspace.id)
        let model = app.existingModel(for: workspace.id)
        guard model?.isRunningSetup != true else { throw ConversationRewindError.busy }
        for session in sessions {
            let live = model?.existingTranscript(for: session.id)
            guard !session.state.isMidTurn, live?.isRunning != true, live?.isAwaitingPermission != true, live?.sending == nil,
                  live?.backgroundWork == nil, live?.subagents.isWorking != true,
                  live?.history.isCapturing != true, live?.history.isFinalisingTurn != true, live?.history.hasActiveTurn != true,
                  try await store.pendingDeliveries(sessionID: session.id).isEmpty else {
                throw ConversationRewindError.busy
            }
        }
    }

    private func requireAttachments(_ prompt: String, cwd: String) throws {
        for path in AttachmentDraft.parse(prompt).paths {
            guard FileManager.default.fileExists(atPath: PromptAttachment.sent(path: path).url(in: cwd).path) else {
                throw SnapshotFailure("An attachment from this message is missing: \(path)")
            }
        }
    }
}
