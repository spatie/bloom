import Foundation

/// Hundreds of simultaneous SQLite migrations and repository copies can occupy every executor
/// thread long enough to expire unrelated agent deadlines. Queue fixture-owning test cases before
/// they start that work; tasks within each test remain concurrent.
actor TestWorkloadLimit {
    static let shared = TestWorkloadLimit(capacity: 8)
    @TaskLocal static var isHeld = false

    private var available: Int
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init(capacity: Int) {
        precondition(capacity > 0)
        available = capacity
    }

    var waitingCount: Int { waiters.count }
    var availableCount: Int { available }

    func acquire() async throws {
        try Task.checkCancellation()
        if available > 0 {
            available -= 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func release() {
        if waiters.isEmpty { available += 1 } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
