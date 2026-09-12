import Foundation
import Synchronization

/// A workspace transition first closes admission, then drains operations that already entered.
/// RPC and MCP use the same tickets, so archive cannot miss a tool paused in agent discovery.
final class ServerWorkspaceAdmissions: Sendable {
    struct Permit: Sendable {
        fileprivate let owner: ServerWorkspaceAdmissions
        fileprivate let workspaceID: WorkspaceID
        fileprivate let id: UUID
        func release() { owner.release(self) }
    }
    struct Transition: Sendable {
        fileprivate let owner: ServerWorkspaceAdmissions
        fileprivate let workspaceID: WorkspaceID
        fileprivate let id: UUID
        func drain() async throws { try await owner.drain(self) }
        func finish(closed: Bool) { owner.finish(self, closed: closed) }
    }
    private enum Phase { case open, closing(UUID), closed }
    private struct Entry {
        var phase = Phase.open
        var permits: Set<UUID> = []
        var waiter: CheckedContinuation<Void, Error>?
    }
    private struct State {
        var stopped = false
        var entries: [WorkspaceID: Entry] = [:]
        var idleWaiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())

    func admit(_ workspaceID: WorkspaceID) throws -> Permit {
        try state.withLock { state in
            guard !state.stopped else { throw ServerFailure("The server is shutting down.") }
            var entry = state.entries[workspaceID] ?? Entry()
            guard case .open = entry.phase else { throw ServerFailure("This workspace is being archived or restored. Try again shortly.") }
            let id = UUID()
            entry.permits.insert(id); state.entries[workspaceID] = entry
            return Permit(owner: self, workspaceID: workspaceID, id: id)
        }
    }

    func beginTransition(_ workspaceID: WorkspaceID) throws -> Transition {
        try state.withLock { state in
            guard !state.stopped else { throw ServerFailure("The server is shutting down.") }
            var entry = state.entries[workspaceID] ?? Entry()
            if case .closing = entry.phase { throw ServerFailure("This workspace is already being changed.") }
            let id = UUID()
            entry.phase = .closing(id); state.entries[workspaceID] = entry
            return Transition(owner: self, workspaceID: workspaceID, id: id)
        }
    }

    private func release(_ permit: Permit) {
        let ready = state.withLock { state -> (CheckedContinuation<Void, Error>?, [CheckedContinuation<Void, Never>]) in
            guard var entry = state.entries[permit.workspaceID], entry.permits.remove(permit.id) != nil else { return (nil, []) }
            let waiter = entry.permits.isEmpty ? entry.waiter : nil
            if waiter != nil { entry.waiter = nil }
            state.entries[permit.workspaceID] = entry
            if case .open = entry.phase, entry.permits.isEmpty { state.entries[permit.workspaceID] = nil }
            let idle = state.entries.values.allSatisfy { $0.permits.isEmpty }
            let shutdown = idle ? state.idleWaiters : []
            if idle { state.idleWaiters.removeAll() }
            return (waiter, shutdown)
        }
        ready.0?.resume()
        for waiter in ready.1 { waiter.resume() }
    }

    private func drain(_ transition: Transition) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                state.withLock { state in
                    guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                    guard !state.stopped, var entry = state.entries[transition.workspaceID],
                          case .closing(transition.id) = entry.phase else {
                        continuation.resume(throwing: ServerFailure("The workspace transition ended.")); return
                    }
                    guard entry.waiter == nil else {
                        continuation.resume(throwing: ServerFailure("The workspace is already waiting for its operations.")); return
                    }
                    if entry.permits.isEmpty { continuation.resume(); return }
                    entry.waiter = continuation; state.entries[transition.workspaceID] = entry
                }
            }
        } onCancel: { self.cancelDrain(transition) }
    }

    private func cancelDrain(_ transition: Transition) {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Error>? in
            guard var entry = state.entries[transition.workspaceID], case .closing(transition.id) = entry.phase else { return nil }
            defer { entry.waiter = nil; state.entries[transition.workspaceID] = entry }
            return entry.waiter
        }
        waiter?.resume(throwing: CancellationError())
    }

    private func finish(_ transition: Transition, closed: Bool) {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Error>? in
            guard var entry = state.entries[transition.workspaceID], case .closing(transition.id) = entry.phase else { return nil }
            let waiter = entry.waiter
            entry.waiter = nil; entry.phase = closed ? .closed : .open
            state.entries[transition.workspaceID] = entry
            if !closed, entry.permits.isEmpty { state.entries[transition.workspaceID] = nil }
            return waiter
        }
        waiter?.resume(throwing: CancellationError())
    }

    var waitingCount: Int { state.withLock { $0.entries.values.filter { $0.waiter != nil }.count } }
    var hasActiveOperations: Bool {
        state.withLock { $0.entries.values.contains { entry in
            if case .closing = entry.phase { return true }
            return !entry.permits.isEmpty
        } }
    }

    func stop() {
        let waiters = state.withLock { state in
            state.stopped = true
            let waiters = state.entries.values.compactMap(\.waiter)
            for id in state.entries.keys { state.entries[id]?.waiter = nil }
            return waiters
        }
        for waiter in waiters { waiter.resume(throwing: ServerFailure("The server is shutting down.")) }
    }

    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            state.withLock { state in
                if state.entries.values.allSatisfy({ $0.permits.isEmpty }) { continuation.resume() } else { state.idleWaiters.append(continuation) }
            }
        }
    }
}
