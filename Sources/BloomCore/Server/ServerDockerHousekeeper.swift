import Foundation

/// Carries out `ServerDockerHousekeeping` in the background of a running server.
///
/// Every entry point returns at once. A setup that finished is never held up by a prune, and a
/// prune that fails, or finds Docker missing or not Bloom's private rootless engine, is dropped
/// without a word: the storage report and the disk check already say what a person needs to know.
actor ServerDockerHousekeeper {
    typealias Disk = @Sendable () -> (total: Int64?, free: Int64?)
    typealias Prune = @Sendable (ServerDockerHousekeeping.Prune) async -> Bool

    private let disk: Disk
    private let prune: Prune
    private let now: @Sendable () -> Date
    private var state = ServerDockerHousekeeping()
    private var running = false
    private var periodic: Task<Void, Never>?

    init(storage: ServerStorageService) {
        self.init(disk: { storage.diskSpace() }, prune: { await storage.housekeepingPrune($0) })
    }

    init(disk: @escaping Disk, prune: @escaping Prune, now: @escaping @Sendable () -> Date = Date.init) {
        self.disk = disk; self.prune = prune; self.now = now
    }

    nonisolated func setupEnded(succeeded: Bool) {
        Task { await run(succeeded ? .setupSucceeded : .diskCheck) }
    }

    nonisolated func startPeriodicChecks() {
        Task { await beginPeriodicChecks() }
    }

    nonisolated func stop() {
        Task { await cancelPeriodicChecks() }
    }

    var notice: String? { state.notice }

    func run(_ trigger: ServerDockerHousekeeping.Trigger) async {
        guard !running else { return }
        let before = disk()
        let plan = state.plan(trigger, totalBytes: before.total, freeBytes: before.free, now: now())
        guard !plan.isEmpty else { return }
        running = true
        defer { running = false }
        for item in plan { _ = await prune(item) }
        if plan.contains(where: { $0 != .danglingImages }) {
            let after = disk()
            state.recordCleanup(totalBytes: after.total, freeBytes: after.free, now: now())
        }
    }

    private func beginPeriodicChecks() {
        guard periodic == nil else { return }
        periodic = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(ServerDockerHousekeeping.checkInterval)) } catch { return }
                await self?.run(.diskCheck)
            }
        }
    }

    private func cancelPeriodicChecks() {
        periodic?.cancel()
        periodic = nil
    }
}
