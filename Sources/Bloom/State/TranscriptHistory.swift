import Foundation
import Observation
import BloomCore

@MainActor
@Observable
final class TranscriptHistory {
    var checkpoints: [TurnCheckpoint] = []
    var failure: String?
    private(set) var isCapturing = false
    var isFinalisingTurn = false
    var hasActiveTurn: Bool { active != nil }
    @ObservationIgnored private var active: TurnCheckpoint?

    func load(store: Store, sessionID: SessionID) async {
        do {
            checkpoints = try await store.turnCheckpoints(sessionID: sessionID)
        } catch { failure = "Could not load turn history: \(error.localizedDescription)" }
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
            failure = nil
        } catch { failure = "Could not capture this turn's starting state: \(error)" }
    }

    func finish(store: Store, cwd: String, endSeq: Int, captureFiles: Bool = true) async {
        guard let checkpoint = active else { return }
        active = nil
        isCapturing = true
        defer { isCapturing = false }
        do {
            if !captureFiles {
                var closed = checkpoint
                closed.endSeq = max(endSeq, checkpoint.startSeq)
                try await store.saveTurnCheckpoint(closed)
                merge(try await store.turnCheckpoints(sessionID: checkpoint.sessionID))
                failure = "This turn's final file snapshot is unavailable because another turn had already started."
                return
            }
            _ = try await TurnCheckpointStore(store: store).finish(
                id: checkpoint.id, sessionID: checkpoint.sessionID, cwd: cwd, endSeq: max(endSeq, checkpoint.startSeq)
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
            return merged
        }
    }

    func files(_ checkpoint: TurnCheckpoint, cwd: String) async throws -> [ChangedFile] {
        guard let after = checkpoint.after else { throw SnapshotFailure("This turn has no completed snapshot.") }
        return try await Git.snapshotFiles(from: checkpoint.before, to: after, in: cwd)
    }
}
