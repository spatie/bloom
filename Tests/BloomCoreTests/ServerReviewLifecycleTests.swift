import Foundation
import Testing
@testable import BloomCore

@Suite("Review shutdown lifecycle", .scratchDirectory, .tags(.subprocess))
struct ServerReviewLifecycleTests {
    @Test func closedCacheRejectsPatchesWithoutStartingGit() async throws {
        let cache = ServerReviewCache()
        await cache.shutdown()
        let workspace = Workspace(repoID: .new(), name: "Closed", branch: "main", path: "/missing-review-fixture", baseBranch: "main")
        do {
            _ = try await cache.patch(workspace: workspace, path: "file.txt", scope: .branch)
            Issue.record("A closed cache accepted a patch")
        } catch { #expect(error.localizedDescription == "The review connection closed.") }
        #expect(await cache.metrics.scans == 0)
    }

    @Test func shutdownDrainsWatcherDiscoveryAndCannotRepopulateTheCache() async throws {
        let gate = ReviewDiscoveryGate()
        let cache = ServerReviewCache { workspace in
            await withTaskCancellationHandler {
                await gate.hold()
                return [workspace.path]
            } onCancel: { Task { await gate.cancelled() } }
        }
        let workspace = Workspace(repoID: .new(), name: "Held", branch: "main", path: TestScratch.unique("review-roots"), baseBranch: "main")
        let reading = Task { try await cache.patch(workspace: workspace, path: "file.txt", scope: .branch) }
        await gate.waitForStart()
        let shutdown = Task { await cache.shutdown(); await gate.finished() }
        await gate.waitForCancellation()
        #expect(await gate.isFinished == false)
        await gate.release()
        await shutdown.value
        await #expect(throws: (any Error).self) { try await reading.value }
        #expect(await cache.metrics.scans == 0)
        #expect(await cache.metrics.retainedPatchBytes == 0)
        await cache.shutdown()
    }

    @Test func cancelledQueuedPatchDoesNotWaitForOrConsumeAWorker() async throws {
        let workers = ReviewWorkers(maximum: 1)
        try await workers.acquire()
        let waiting = Task { try await workers.acquire() }
        await waitUntil("patch waits behind active worker") { await workers.waitingCount == 1 }
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(await workers.waitingCount == 0)
        await workers.release()
        try await workers.acquire()
        await workers.release()
    }
}

private actor ReviewDiscoveryGate {
    private var started = false, wasCancelled = false
    private var startWait: CheckedContinuation<Void, Never>?
    private var cancelWait: CheckedContinuation<Void, Never>?
    private var held: CheckedContinuation<Void, Never>?
    private(set) var isFinished = false
    func hold() async {
        started = true; startWait?.resume(); startWait = nil
        await withCheckedContinuation { held = $0 }
    }
    func waitForStart() async { if !started { await withCheckedContinuation { startWait = $0 } } }
    func cancelled() { wasCancelled = true; cancelWait?.resume(); cancelWait = nil }
    func waitForCancellation() async { if !wasCancelled { await withCheckedContinuation { cancelWait = $0 } } }
    func release() { held?.resume(); held = nil }
    func finished() { isFinished = true }
}
