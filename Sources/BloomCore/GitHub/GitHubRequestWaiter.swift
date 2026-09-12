import Foundation
import Synchronization

/// Cancellation belongs to the subscriber, not to a shared request. A continuation lets a
/// disappeared inspector leave immediately while a sidebar keeps waiting for the same result.
private final class GitHubWaitGate: Sendable {
    private struct State {
        var continuation: CheckedContinuation<ShellResult, Error>?
        var result: Result<ShellResult, Error>?
    }
    private let state = Mutex(State())

    func install(_ continuation: CheckedContinuation<ShellResult, Error>) {
        let result = state.withLock { state -> Result<ShellResult, Error>? in
            if let result = state.result { return result }
            state.continuation = continuation
            return nil as Result<ShellResult, Error>?
        }
        if let result { continuation.resume(with: result) }
    }

    func finish(_ result: Result<ShellResult, Error>) {
        let continuation = state.withLock { state in
            guard state.result == nil else { return nil as CheckedContinuation<ShellResult, Error>? }
            state.result = result
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}

enum GitHubRequestWaiter {
    static func value(of task: Task<ShellResult, Error>) async throws -> ShellResult {
        let gate = GitHubWaitGate()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                Task {
                    do { gate.finish(.success(try await task.value)) } catch { gate.finish(.failure(error)) }
                }
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }
}
