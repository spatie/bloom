import Testing

@Suite struct TestWorkloadLimitTests {
    @Test func aQueuedTestWaitsForAnExistingPermitToBeReleased() async throws {
        let limit = TestWorkloadLimit(capacity: 2)
        try await limit.acquire()
        try await limit.acquire()
        let queued = Task { try await limit.acquire() }
        defer { queued.cancel() }
        await waitUntil("the third test is queued") { await limit.waitingCount == 1 }
        #expect(await limit.availableCount == 0)
        await limit.release()
        try await queued.value
        #expect(await limit.waitingCount == 0)
        #expect(await limit.availableCount == 0)
        await limit.release()
        await limit.release()
        #expect(await limit.availableCount == 2)
    }

    @Test func cancellingAQueuedTestDoesNotConsumeTheNextPermit() async throws {
        let limit = TestWorkloadLimit(capacity: 1)
        try await limit.acquire()
        let cancelled = Task { try await limit.acquire() }
        defer { cancelled.cancel() }
        await waitUntil("the cancelled test is queued") { await limit.waitingCount == 1 }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(await limit.waitingCount == 0)
        await limit.release()
        try await limit.acquire()
        #expect(await limit.availableCount == 0)
        await limit.release()
        #expect(await limit.availableCount == 1)
    }
}
