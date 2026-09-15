import Foundation

/// Cancellation removes a waiting load, but an active load keeps its slot until its transport
/// actually returns. A scope change cannot exceed the limit when an old read ignores cancellation.
@MainActor
final class ReviewLoadLimit {
    private let maximum: Int
    private var active: Set<UUID> = []
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []

    init(maximum: Int) { self.maximum = max(1, maximum) }

    func acquire(_ id: UUID) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if active.count < maximum { active.insert(id); continuation.resume() } else { waiting.append((id, continuation)) }
            }
        } onCancel: {
            Task { @MainActor in self.cancelWaiting(id) }
        }
    }

    func release(_ id: UUID) {
        guard active.remove(id) != nil else { return }
        if !waiting.isEmpty {
            let next = waiting.removeFirst()
            active.insert(next.0)
            next.1.resume()
        }
    }

    private func cancelWaiting(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: index).1.resume(throwing: CancellationError())
    }
}
