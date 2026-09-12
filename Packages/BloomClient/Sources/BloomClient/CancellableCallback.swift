/// Adapts a main-actor callback API whose callbacks may arrive after its caller is cancelled.
/// Cancellation completes the awaiting task even if the underlying API never calls back.
@MainActor
public enum CancellableCallback<Value: Sendable> {
    public static func run(
        _ start: (@escaping @MainActor (Result<Value, Error>) -> Void) -> Void
    ) async throws -> Value {
        let pending = PendingCallback<Value>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending.continuation = continuation
                start { result in pending.finish(result) }
            }
        } onCancel: {
            Task { @MainActor in pending.finish(.failure(CancellationError())) }
        }
    }
}

@MainActor
private final class PendingCallback<Value: Sendable> {
    var continuation: CheckedContinuation<Value, Error>?

    func finish(_ result: Result<Value, Error>) {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}
