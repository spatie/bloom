import Foundation
import Observation
import BloomCore

@MainActor
@Observable
final class TranscriptHistory {
    var checkpoints: [TurnCheckpoint] = []
    private(set) var isCapturing = false
    var isFinalisingTurn = false
    var hasActiveTurn: Bool { active != nil }
    @ObservationIgnored private var active: TurnCheckpoint?
    /// Where a failure is said. A toast rather than a strip above the composer: the strip sat
    /// under "Running Bash" while the turn carried on, and read as part of the work in progress
    /// rather than as a note that this turn's file list would be missing.
    @ObservationIgnored var report: (String) -> Void = { _ in }

    func load(store: Store, sessionID: SessionID) async {
        do {
            checkpoints = try await store.turnCheckpoints(sessionID: sessionID)
        } catch { report("Could not load this conversation's turn history. \(error.readableMessage)") }
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
        } catch { report("This turn's file changes will not be listed. \(error.readableMessage)") }
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
                report("This turn's file changes will not be listed. Another turn had already started before it finished.")
                return
            }
            _ = try await TurnCheckpointStore(store: store).finish(
                id: checkpoint.id, sessionID: checkpoint.sessionID, cwd: cwd, endSeq: max(endSeq, checkpoint.startSeq)
            )
            merge(try await store.turnCheckpoints(sessionID: checkpoint.sessionID))
        } catch { report("This turn's file changes will not be listed. \(error.readableMessage)") }
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
