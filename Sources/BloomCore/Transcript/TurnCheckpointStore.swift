import Foundation

/// Git owns file contents; Store owns their association with transcript rows. A checkpoint is
/// taken before the send and after the result, so shell edits and repeated edits are net changes.
public actor TurnCheckpointStore {
    private let store: Store
    private var preparing: Set<SessionID> = []
    private var completing: [GitSnapshotID: Task<TurnCheckpoint, Error>] = [:]

    public init(store: Store) { self.store = store }

    public func begin(sessionID: SessionID, cwd: String, startSeq: Int) async throws -> TurnCheckpoint {
        let snapshot = try await Git.captureSnapshot(in: cwd, sessionID: sessionID)
        let checkpoint = TurnCheckpoint(sessionID: sessionID, startSeq: startSeq, before: snapshot)
        do { try await store.saveTurnCheckpoint(checkpoint) } catch {
            try? await Git.deleteSnapshot(snapshot, in: cwd)
            throw error
        }
        return checkpoint
    }

    @discardableResult
    public func finish(
        id: GitSnapshotID, sessionID: SessionID, cwd: String, endSeq: Int, providerTurnID: String? = nil
    ) async throws -> TurnCheckpoint {
        if let task = completing[id] { return try await task.value }
        let task = Task {
            try await complete(id: id, sessionID: sessionID, cwd: cwd, endSeq: endSeq, providerTurnID: providerTurnID)
        }
        completing[id] = task
        defer { completing[id] = nil }
        return try await task.value
    }

    private func complete(
        id: GitSnapshotID, sessionID: SessionID, cwd: String, endSeq: Int, providerTurnID: String?
    ) async throws -> TurnCheckpoint {
        guard var checkpoint = try await list(sessionID: sessionID).first(where: { $0.id == id }) else {
            throw SnapshotFailure("The turn's starting snapshot is unavailable.")
        }
        if checkpoint.endSeq != nil { return checkpoint }
        let after = try await Git.captureSnapshot(in: cwd, sessionID: sessionID)
        checkpoint.after = after
        checkpoint.endSeq = endSeq
        checkpoint.providerTurnID = providerTurnID
        do { try await store.saveTurnCheckpoint(checkpoint) } catch {
            try? await Git.deleteSnapshot(after, in: cwd)
            throw error
        }
        // Bound hidden refs as well as metadata. Old conversations retain their transcript, but
        // only the most recent 200 completed turns keep restorable filesystem snapshots.
        let retired = try await store.pruneTurnCheckpoints(sessionID: sessionID, keepingLast: 200)
        for record in retired {
            for snapshot in [record.before, record.after].compactMap({ $0 }) {
                try? await Git.deleteSnapshot(snapshot, in: cwd)
            }
        }
        return checkpoint
    }

    public func list(sessionID: SessionID) async throws -> [TurnCheckpoint] {
        try await store.turnCheckpoints(sessionID: sessionID)
    }

    public func diff(_ checkpoint: TurnCheckpoint, cwd: String, path: String? = nil) async throws -> String {
        guard let after = checkpoint.after else { throw SnapshotFailure("This turn has no completed snapshot.") }
        return try await Git.snapshotDiff(from: checkpoint.before, to: after, in: cwd, path: path)
    }

    public func prepareRewind(
        checkpoint: TurnCheckpoint, cwd: String, restoringFiles: Bool,
        operationLease: WorkspaceOperationLease? = nil
    ) async throws -> CheckpointRewind {
        guard let lease = operationLease ?? WorkspaceOperationLease.acquire(in: cwd, operation: .rewind),
              lease.isValid(in: cwd, operation: .rewind) else {
            throw SnapshotFailure("Setup or another rewind is already using this worktree.")
        }
        defer { if operationLease == nil { lease.release() } }
        guard preparing.insert(checkpoint.sessionID).inserted else {
            throw SnapshotFailure("A rewind is already being prepared for this conversation.")
        }
        defer { preparing.remove(checkpoint.sessionID) }
        let previous = try await store.checkpointRewind(sessionID: checkpoint.sessionID)
        if let previous, previous.stage != .complete {
            throw SnapshotFailure("Resolve the previous interrupted rewind before starting another.")
        }
        if restoringFiles { try await Git.validateSnapshotRestore(checkpoint.before, in: cwd) }
        let recovery = restoringFiles ? try await Git.captureSnapshot(in: cwd, sessionID: checkpoint.sessionID) : nil
        let journal = CheckpointRewind(checkpoint: checkpoint, recovery: recovery, restoringFiles: restoringFiles)
        do { try await store.saveCheckpointRewind(journal) } catch {
            if let recovery { try? await Git.deleteSnapshot(recovery, in: cwd) }
            throw error
        }
        // The new journal is durable before old recovery refs are retired. A checkpoint still
        // listed in turn history remains protected even when its previous rewind is superseded.
        if let previous {
            let records = try await store.turnCheckpoints(sessionID: checkpoint.sessionID)
            let retained = Set(records.flatMap { [$0.before.id, $0.after?.id].compactMap { $0 } }
                + [checkpoint.before.id, checkpoint.after?.id, recovery?.id].compactMap { $0 })
            for snapshot in [previous.checkpoint.before, previous.checkpoint.after, previous.recovery].compactMap({ $0 })
                where !retained.contains(snapshot.id) {
                try? await Git.deleteSnapshot(snapshot, in: cwd)
            }
        }
        return journal
    }

    public func markRewind(_ journal: CheckpointRewind) async throws {
        try await store.saveCheckpointRewind(journal)
    }

    public func pendingRewind(sessionID: SessionID) async throws -> CheckpointRewind? {
        let journal = try await store.checkpointRewind(sessionID: sessionID)
        return journal?.stage == .complete ? nil : journal
    }

    public func removeAfter(sessionID: SessionID, seq: Int, cwd: String) async throws {
        let removed = try await store.removeTurnCheckpoints(sessionID: sessionID, fromSeq: seq)
        try await store.queueRetiredCheckpoints(removed, sessionID: sessionID)
        try await cleanupRetired(sessionID: sessionID, cwd: cwd)
    }

    public func cleanupRetired(sessionID: SessionID, cwd: String) async throws {
        let removed = try await store.retiredRewindCheckpoints(sessionID: sessionID)
        // Keep refs referenced by the recovery journal. They are the recovery path even after the
        // conversation has been rewound successfully, until another rewind supersedes it.
        let journal = try await store.checkpointRewind(sessionID: sessionID)
        let protected = [journal?.checkpoint.before.id, journal?.checkpoint.after?.id, journal?.recovery?.id].compactMap { $0 }
        var completed = Set<GitSnapshotID>()
        for record in removed {
            let snapshots = [record.before, record.after].compactMap { $0 }
            guard !snapshots.contains(where: { protected.contains($0.id) }) else { continue }
            do {
                for snapshot in snapshots { try await Git.deleteSnapshot(snapshot, in: cwd) }
                completed.insert(record.id)
            } catch {
                // Leave failed cleanup in the durable queue for the next load or rewind.
            }
        }
        try await store.acknowledgeRetiredCheckpoints(completed, sessionID: sessionID)
    }
}
