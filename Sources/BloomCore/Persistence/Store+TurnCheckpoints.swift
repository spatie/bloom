import Foundation

extension Store {
    public func turnCheckpoints(sessionID: SessionID) throws -> [TurnCheckpoint] {
        guard let value = try setting("turn.checkpoints.\(sessionID)") else { return [] }
        return try JSONDecoder().decode([TurnCheckpoint].self, from: Data(value.utf8))
    }

    /// This read/modify/write has no suspension and belongs to the Store actor. Two completed
    /// turns cannot overwrite each other's checkpoint metadata with an old whole-session value.
    public func saveTurnCheckpoint(_ checkpoint: TurnCheckpoint) throws {
        var records = try turnCheckpoints(sessionID: checkpoint.sessionID)
        if let index = records.firstIndex(where: { $0.id == checkpoint.id }) {
            let current = records[index]
            guard current.startSeq == checkpoint.startSeq, current.before == checkpoint.before else {
                throw SnapshotFailure("A checkpoint update cannot change its starting boundary.")
            }
            var merged = checkpoint
            if current.endSeq != nil {
                merged.after = current.after
                merged.endSeq = current.endSeq
            }
            merged.providerTurnID = current.providerTurnID ?? checkpoint.providerTurnID
            records[index] = merged
        } else { records.append(checkpoint) }
        records.sort { $0.startSeq < $1.startSeq }
        try setSetting("turn.checkpoints.\(checkpoint.sessionID)", String(decoding: JSONEncoder().encode(records), as: UTF8.self))
    }

    /// The provider may answer while completion is between capture and refreshing the UI list.
    /// Link inside the Store actor regardless of which transient UI collection holds the turn.
    @discardableResult
    public func linkTurnCheckpoint(sessionID: SessionID, startSeq: Int, providerTurnID: String) throws -> Bool {
        var records = try turnCheckpoints(sessionID: sessionID)
        guard let index = records.indices.filter({ records[$0].startSeq == startSeq }).max(by: {
            records[$0].before.createdAt < records[$1].before.createdAt
        }) else { return false }
        if let current = records[index].providerTurnID, current != providerTurnID {
            throw SnapshotFailure("This snapshot is already linked to a different agent turn.")
        }
        records[index].providerTurnID = providerTurnID
        try setSetting("turn.checkpoints.\(sessionID)", String(decoding: JSONEncoder().encode(records), as: UTF8.self))
        return true
    }

    @discardableResult
    public func removeTurnCheckpoints(sessionID: SessionID, fromSeq: Int) throws -> [TurnCheckpoint] {
        let records = try turnCheckpoints(sessionID: sessionID)
        let removed = records.filter { $0.startSeq >= fromSeq }
        let retained = records.filter { $0.startSeq < fromSeq }
        try setSetting("turn.checkpoints.\(sessionID)", String(decoding: JSONEncoder().encode(retained), as: UTF8.self))
        return removed
    }

    public func checkpointRewind(sessionID: SessionID) throws -> CheckpointRewind? {
        guard let value = try setting("turn.rewind.\(sessionID)") else { return nil }
        return try JSONDecoder().decode(CheckpointRewind.self, from: Data(value.utf8))
    }

    public func saveCheckpointRewind(_ rewind: CheckpointRewind) throws {
        if rewind.stage == .prepared,
           let session = try session(id: rewind.checkpoint.sessionID),
           let workspaceID = session.workspaceID,
           let workspace = try workspace(id: workspaceID),
           workspace.setupState == .running || WorkspaceOperationLease.isHeld(in: workspace.path, operation: .setup) {
            throw SnapshotFailure("Setup is using this worktree. Wait for it to finish before rewinding.")
        }
        if let current = try checkpointRewind(sessionID: rewind.checkpoint.sessionID) {
            if current.token != rewind.token {
                guard current.stage == .complete, rewind.stage == .prepared else {
                    throw SnapshotFailure("A different rewind already owns this recovery record.")
                }
            } else {
                let rank: [CheckpointRewind.Stage: Int] = [
                    .prepared: 0, .filesRestored: 1, .failed: 1, .providerReverted: 2, .complete: 3,
                ]
                guard (rank[rewind.stage] ?? 0) >= (rank[current.stage] ?? 0) else {
                    throw SnapshotFailure("A stale rewind update cannot replace a completed recovery step.")
                }
            }
        }
        try setSetting("turn.rewind.\(rewind.checkpoint.sessionID)", String(decoding: JSONEncoder().encode(rewind), as: UTF8.self))
    }

    public func pruneTurnCheckpoints(sessionID: SessionID, keepingLast limit: Int) throws -> [TurnCheckpoint] {
        let records = try turnCheckpoints(sessionID: sessionID)
        let complete = records.filter { $0.endSeq != nil }
        let kept = Set(complete.suffix(max(1, limit)).map(\.id))
        let journal = try checkpointRewind(sessionID: sessionID)
        let removed = complete.filter { !kept.contains($0.id) && $0.id != journal?.checkpoint.id }
        let removedIDs = Set(removed.map(\.id))
        let retained = records.filter { !removedIDs.contains($0.id) }
        try setSetting("turn.checkpoints.\(sessionID)", String(decoding: JSONEncoder().encode(retained), as: UTF8.self))
        return removed
    }
}
