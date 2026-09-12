import Testing
@testable import BloomClient

@MainActor
struct CancellableCallbackTests {
    @Test func synchronousCompletionOnlyResumesOnce() async throws {
        let value = try await CancellableCallback<Int>.run { completion in
            completion(.success(42))
            completion(.success(99))
        }
        #expect(value == 42)
    }

    @Test func cancellationFinishesWithoutUnderlyingCallbackAndIgnoresLateReply() async throws {
        var callback: (@MainActor (Result<Int, Error>) -> Void)?
        let task = Task { try await CancellableCallback<Int>.run { callback = $0 } }
        while callback == nil { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        callback?(.success(99))
        callback?(.failure(CancellationError()))
    }

    @Test func cancelledCallerDoesNotStartWork() async {
        var started = false
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CancellableCallback<Int>.run { completion in
                started = true
                completion(.success(42))
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!started)
    }
}
