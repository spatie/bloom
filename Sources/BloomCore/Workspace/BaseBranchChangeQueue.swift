import Foundation

/// A newer poll invalidates a target still being fetched. Once a write starts, the next write
/// waits for both git config and the store, so their suspension points cannot reverse the order.
@MainActor
public final class BaseBranchChangeQueue {
    public struct Request: Equatable, Sendable {
        fileprivate let workspaceID: WorkspaceID
        fileprivate let id = UUID()
    }

    private var latest: [WorkspaceID: Request] = [:]
    private var writes: [WorkspaceID: Task<Void, Never>] = [:]

    public init() {}

    /// Called before preparing a new target, so a newer choice invalidates an older fetch.
    public func begin(for workspaceID: WorkspaceID) -> Request {
        let request = Request(workspaceID: workspaceID)
        latest[workspaceID] = request
        return request
    }

    public func isCurrent(_ request: Request) -> Bool {
        latest[request.workspaceID] == request
    }

    /// Preparation, including fetching, happens before this call. A superseded answer never
    /// reaches the writer, even when the operation ahead of it suspended in git or SQLite.
    public func write(
        _ request: Request, isCurrent: @MainActor @escaping () -> Bool = { true },
        operation: @MainActor @escaping () async -> Void
    ) async {
        let workspaceID = request.workspaceID
        guard self.isCurrent(request), isCurrent() else { return }
        let previous = writes[workspaceID]
        let task = Task { @MainActor in
            await previous?.value
            guard self.isCurrent(request), isCurrent() else { return }
            await operation()
        }
        writes[workspaceID] = task
        await task.value
        if writes[workspaceID] == task { writes[workspaceID] = nil }
    }
}
