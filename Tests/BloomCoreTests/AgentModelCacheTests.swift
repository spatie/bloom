import Foundation
import Synchronization
import Testing
@testable import BloomCore

@Suite struct AgentModelCacheTests {
    private enum FetchFailure: Error { case offline }

    private actor Attempts {
        private var count = 0

        func fetch() throws -> [CodexModel] {
            count += 1
            if count == 1 { throw FetchFailure.offline }
            return [CodexModel(id: "test", displayName: "Test")]
        }
    }

    @Test func codexRetriesFailedDiscovery() async throws {
        let attempts = Attempts()
        let catalog = CodexModelCatalog(fetch: { try await attempts.fetch() })
        await #expect(throws: FetchFailure.self) { try await catalog.models() }
        let models = try await catalog.models()
        let cached = try await catalog.models()
        #expect(models.map(\.id) == ["test"])
        #expect(cached == models)
        #expect(await catalog.fetchCount == 2)
    }

    private actor ControlledFetch {
        nonisolated let started: AsyncStream<Int>
        private let continuation: AsyncStream<Int>.Continuation
        private var pending: [Int: CheckedContinuation<[String], any Error>] = [:]
        private var count = 0

        init() {
            (started, continuation) = AsyncStream.makeStream()
        }

        func fetch() async throws -> [String] {
            count += 1
            // An accidental extra fetch produces an assertion failure instead of hanging a test.
            guard count <= 2 else { return ["unexpected fetch"] }
            let request = count
            continuation.yield(request)
            return try await withCheckedThrowingContinuation { pending[request] = $0 }
        }

        func finish(_ request: Int, with result: Result<[String], any Error>) {
            pending.removeValue(forKey: request)?.resume(with: result)
        }
    }

    @Test(arguments: [false, true])
    func invalidatedFetchCannotReplaceOrClearItsSuccessor(fails: Bool) async throws {
        let source = ControlledFetch()
        var started = source.started.makeAsyncIterator()
        let cache = AgentModelCache(fetch: { try await source.fetch() })
        let old = Task { try await cache.models() }
        let firstRequest = await started.next()
        #expect(firstRequest == 1)
        await cache.invalidate()
        let replacement = Task { try await cache.models() }
        let secondRequest = await started.next()
        #expect(secondRequest == 2)

        await source.finish(1, with: fails ? .failure(FetchFailure.offline) : .success(["old"]))
        _ = await old.result
        #expect(await cache.lastKnown.isEmpty)
        await source.finish(2, with: .success(["new"]))
        #expect(try await replacement.value == ["new"])
        let cached = try await cache.models()
        #expect(cached == ["new"])
        #expect(await cache.fetchCount == 2)
    }

    @Test func cancellingOneCallerDoesNotDiscardDiscovery() async throws {
        let source = ControlledFetch()
        var started = source.started.makeAsyncIterator()
        let cache = AgentModelCache(fetch: { try await source.fetch() })
        let caller = Task { try await cache.models() }
        let firstRequest = await started.next()
        #expect(firstRequest == 1)
        caller.cancel()
        let other = Task { try await cache.models() }
        await source.finish(1, with: .success(["shared"]))
        _ = await caller.result
        #expect(try await other.value == ["shared"])
        #expect(await cache.fetchCount == 1)
    }

    @Test func freshnessExpiresWithoutLosingTheLastKnownList() async throws {
        let clock = Mutex(Date(timeIntervalSince1970: 100))
        let cache = AgentModelCache(fetch: { ["model"] }, now: { clock.withLock { $0 } })
        _ = try await cache.models()
        clock.withLock { $0 += AgentModelCache<String>.freshness - 1 }
        _ = try await cache.models()
        #expect(await cache.fetchCount == 1)
        clock.withLock { $0 += 1 }
        #expect(await cache.lastKnown == ["model"])
        _ = try await cache.models()
        #expect(await cache.fetchCount == 2)
    }
}
