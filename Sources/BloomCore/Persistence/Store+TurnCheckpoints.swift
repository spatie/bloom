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
            records[index] = merged
        } else { records.append(checkpoint) }
        records.sort { $0.startSeq < $1.startSeq }
        try setSetting("turn.checkpoints.\(checkpoint.sessionID)", String(decoding: JSONEncoder().encode(records), as: UTF8.self))
    }

    public func pruneTurnCheckpoints(sessionID: SessionID, keepingLast limit: Int) throws -> [TurnCheckpoint] {
        let records = try turnCheckpoints(sessionID: sessionID)
        let complete = records.filter { $0.endSeq != nil }
        let kept = Set(complete.suffix(max(1, limit)).map(\.id))
        let removed = complete.filter { !kept.contains($0.id) }
        let removedIDs = Set(removed.map(\.id))
        let retained = records.filter { !removedIDs.contains($0.id) }
        try setSetting("turn.checkpoints.\(sessionID)", String(decoding: JSONEncoder().encode(retained), as: UTF8.self))
        return removed
    }
}
