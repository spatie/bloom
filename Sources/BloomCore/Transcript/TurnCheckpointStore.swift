import Foundation

/// Git owns file contents; Store owns their association with transcript rows. A checkpoint is
/// taken before the send and after the result, so shell edits and repeated edits are net changes.
public actor TurnCheckpointStore {
    private let store: Store
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
        id: GitSnapshotID, sessionID: SessionID, cwd: String, endSeq: Int
    ) async throws -> TurnCheckpoint {
        if let task = completing[id] { return try await task.value }
        let task = Task {
            try await complete(id: id, sessionID: sessionID, cwd: cwd, endSeq: endSeq)
        }
        completing[id] = task
        defer { completing[id] = nil }
        return try await task.value
    }

    private func complete(
        id: GitSnapshotID, sessionID: SessionID, cwd: String, endSeq: Int
    ) async throws -> TurnCheckpoint {
        guard var checkpoint = try await list(sessionID: sessionID).first(where: { $0.id == id }) else {
            throw SnapshotFailure("The turn's starting snapshot is unavailable.")
        }
        if checkpoint.endSeq != nil { return checkpoint }
        let after = try await Git.captureSnapshot(in: cwd, sessionID: sessionID)
        checkpoint.after = after
        checkpoint.endSeq = endSeq
        do { try await store.saveTurnCheckpoint(checkpoint) } catch {
            try? await Git.deleteSnapshot(after, in: cwd)
            throw error
        }
        // Bound hidden refs as well as metadata. Old conversations retain their transcript, but
        // only the most recent 200 completed turns keep the snapshots their footers read.
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
}
