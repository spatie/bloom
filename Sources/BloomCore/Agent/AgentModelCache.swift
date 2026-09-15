import Foundation

/// Discovery is shared by callers, but a failed or invalidated fetch must not own the cache.
/// Keeping that rule here prevents each backend from acquiring a different retry policy.
actor AgentModelCache<Model: Sendable> {
    static var freshness: TimeInterval { 15 * 60 }

    private let fetch: @Sendable () async throws -> [Model]
    private let now: @Sendable () -> Date
    private var cached: [Model] = []
    private var fetchedAt: Date?
    private var inFlight: Task<[Model], Error>?
    private(set) var fetchCount = 0

    init(
        fetch: @escaping @Sendable () async throws -> [Model],
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.fetch = fetch
        self.now = now
    }

    func models() async throws -> [Model] {
        if let fetchedAt, now().timeIntervalSince(fetchedAt) < Self.freshness, !cached.isEmpty {
            return cached
        }

        let task: Task<[Model], Error>
        if let running = inFlight {
            task = running
        } else {
            fetchCount += 1
            let fetch = self.fetch
            task = Task { try await fetch() }
            inFlight = task
        }

        // Old callers still receive their result, but cannot cache it or clear a newer fetch.
        // Discovery belongs to all its callers, so cancelling one caller does not cancel it.
        defer { if inFlight == task { inFlight = nil } }
        let models = try await task.value
        if inFlight == task {
            cached = models
            fetchedAt = now()
        }
        return models
    }

    func invalidate() {
        cached = []
        fetchedAt = nil
        inFlight = nil
    }

    var lastKnown: [Model] { cached }
}
