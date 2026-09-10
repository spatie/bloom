import Foundation

/// A deadline must not await a callback API that ignores task cancellation. Cancel the losing
/// tasks and finish exactly once; native handlers must also stop their own pending callbacks.
@MainActor
final class RemoteUIActionRace {
    private var continuation: CheckedContinuation<RemoteUIResult?, Never>?
    private var tasks: [Task<Void, Never>] = []
    private var finished = false

    func run(request: RemoteUIRequest, service: RemoteWorkspaceService, lease: RemoteUILease,
             handler: @escaping @MainActor (RemoteUIAction) async -> RemoteUIResult) async -> RemoteUIResult? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !finished, !Task.isCancelled else { continuation.resume(returning: nil); return }
                self.continuation = continuation
                tasks.append(Task { [weak self] in
                    guard !Task.isCancelled else { return }
                    let result = await handler(request.action)
                    self?.finish(result)
                })
                tasks.append(Task { [weak self] in
                    let remaining = max(0, request.expiresAtMilliseconds - Int64(Date().timeIntervalSince1970 * 1_000))
                    do { try await Task.sleep(for: .milliseconds(min(remaining, 120_000))) } catch { return }
                    self?.finish(.refusal("The UI request timed out. Check the workspace before retrying."))
                })
                tasks.append(Task { [weak self] in
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(for: .milliseconds(250))
                            let claim = try await service.uiBridge(.claim(leaseID: lease.id, token: lease.token, requestID: request.id))
                            guard case .claimed(true) = claim else { self?.finish(nil); return }
                        } catch {
                            // Loss of the authoritative server connection cannot leave a UI action
                            // running without its lease. The next poll exposes connection errors.
                            if !Task.isCancelled { self?.finish(nil) }
                            return
                        }
                    }
                })
            }
        } onCancel: {
            Task { @MainActor in self.finish(nil) }
        }
    }

    private func finish(_ result: RemoteUIResult?) {
        guard !finished else { return }
        finished = true
        let continuation = continuation
        self.continuation = nil
        let tasks = tasks
        self.tasks = []
        for task in tasks { task.cancel() }
        continuation?.resume(returning: result)
    }
}
