import Foundation
import Observation

/// A workspace UI is an explicitly attached client, never a broadcast destination. Both native
/// shells share delivery/retry lifetime; only the action handler knows about views or windows.
@MainActor
@Observable
public final class RemoteUIClientSession {
    public private(set) var isAttached = false
    public private(set) var error: String?
    public let workspaceID: WorkspaceID
    private let clientID: UUID
    private let actions: [String]
    private let handler: @MainActor (RemoteUIAction) async -> RemoteUIResult
    private var work: Task<Void, Never>?
    private var generation = UUID()
    private var lease: RemoteUILease?
    private var service: RemoteWorkspaceService?

    public init(workspaceID: WorkspaceID, clientID: UUID = UUID(), actions: [String],
                handler: @escaping @MainActor (RemoteUIAction) async -> RemoteUIResult) {
        self.workspaceID = workspaceID; self.clientID = clientID
        self.actions = actions; self.handler = handler
    }

    public func start(using service: RemoteWorkspaceService) {
        guard work == nil else { return }
        let generation = UUID()
        self.generation = generation; self.service = service; error = nil
        work = Task { [weak self] in
            guard let self else { return }
            await run(using: service, generation: generation)
            if self.generation == generation { work = nil; isAttached = false }
        }
    }

    public func stop() {
        generation = UUID()
        work?.cancel(); work = nil
        let previous = lease, service = service
        lease = nil; self.service = nil; isAttached = false
        if let previous, let service {
            Task { _ = try? await service.uiBridge(.detach(leaseID: previous.id, token: previous.token)) }
        }
    }

    private func attach(using service: RemoteWorkspaceService, registration: UUID) async throws -> RemoteUIBridgeResult {
        for attempt in 0..<3 {
            do { return try await service.uiBridge(.attach(workspaceID: workspaceID, clientID: clientID, actions: actions), commandID: registration) } catch {
                if error is ConnectionRefusal || Task.isCancelled || attempt == 2 { throw error }
                try await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
            }
        }
        throw ConnectionFailure("The server did not acknowledge this UI attachment.")
    }

    private func run(using service: RemoteWorkspaceService, generation: UUID) async {
        let registration = UUID()
        var completed: [UUID: (result: RemoteUIResult, bytes: Int)] = [:]
        var order: [UUID] = []
        var seen: Set<UUID> = []
        do {
            let result = try await attach(using: service, registration: registration)
            guard case .attached(let attached) = result, attached.workspaceID == workspaceID else {
                throw ConnectionFailure("The server did not attach this workspace's UI.")
            }
            guard self.generation == generation, !Task.isCancelled else {
                _ = try? await service.uiBridge(.detach(leaseID: attached.id, token: attached.token))
                return
            }
            lease = attached; isAttached = true
            while self.generation == generation, !Task.isCancelled {
                let response = try await service.uiBridge(.poll(leaseID: attached.id, token: attached.token, wait: true))
                guard self.generation == generation, !Task.isCancelled else { return }
                guard case .requests(let batch) = response, batch.lease.id == attached.id,
                      batch.lease.workspaceID == workspaceID else {
                    throw ConnectionFailure("The server returned UI work for a different attachment.")
                }
                lease = batch.lease
                for request in batch.requests {
                    guard self.generation == generation, !Task.isCancelled else { return }
                    let claim = try await service.uiBridge(.claim(leaseID: attached.id, token: attached.token, requestID: request.id))
                    guard self.generation == generation, !Task.isCancelled else { return }
                    guard case .claimed(let active) = claim else { throw ConnectionFailure("The server did not validate the UI request.") }
                    guard active else { continue }
                    let result: RemoteUIResult
                    var withdrawn = false
                    if let previous = completed[request.id] {
                        result = previous.result
                    } else if seen.contains(request.id) {
                        result = .refusal("This UI action was already handled. Its cached result expired; inspect the workspace before issuing a new action.")
                    } else if request.workspaceID != workspaceID {
                        result = .refusal("A UI request cannot target another workspace.")
                    } else if request.expiresAtMilliseconds < Int64(Date().timeIntervalSince1970 * 1000) {
                        result = .refusal("This UI request expired before the client could handle it.")
                    } else if !actions.contains(request.action.name) {
                        result = .refusal("This client does not support that UI action.")
                    } else {
                        // Claim local execution before entering a callback. A transient status
                        // failure must never cause the same action to run again on the next poll.
                        seen.insert(request.id)
                        if let performed = await RemoteUIActionRace().run(request: request, service: service, lease: attached, handler: handler) {
                            result = performed
                        } else {
                            result = .refusal("This UI action was interrupted. Inspect the workspace before issuing a new action.")
                            withdrawn = true
                        }
                    }
                    guard self.generation == generation, !Task.isCancelled else { return }
                    if completed[request.id] == nil {
                        seen.insert(request.id)
                        completed[request.id] = (result, (try? JSONEncoder().encode(result).count) ?? Int.max / 64)
                        order.append(request.id)
                        while order.count > 32 || completed.values.reduce(0, { $0 + $1.bytes }) > 16 * 1_024 * 1_024 {
                            guard let oldest = order.first else { break }
                            order.removeFirst(); completed[oldest] = nil
                        }
                    }
                    if withdrawn { continue }
                    // A lost acknowledgement retries the result, never the UI action itself.
                    var acknowledged = false
                    for attempt in 0..<3 {
                        do {
                            let acknowledgement = try await service.uiBridge(.respond(leaseID: attached.id, token: attached.token, requestID: request.id, result: result))
                            guard case .accepted = acknowledgement else { throw ConnectionFailure("The server did not acknowledge the UI result.") }
                            acknowledged = true
                            break
                        } catch {
                            if error is ConnectionRefusal, !Task.isCancelled,
                               case .claimed(false) = try await service.uiBridge(.claim(leaseID: attached.id, token: attached.token, requestID: request.id)) {
                                acknowledged = true // Cancelled work no longer needs a result.
                                break
                            }
                            if Task.isCancelled || attempt == 2 { throw error }
                            try await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
                        }
                    }
                    guard acknowledged else { return }
                }
                if seen.count > 1024 { throw ConnectionFailure("Reconnect agent UI access to start a fresh action history.") }
                if batch.requests.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
            }
        } catch {
            if self.generation == generation, !Task.isCancelled { self.error = error.localizedDescription }
        }
        if let lease, self.generation == generation {
            _ = try? await service.uiBridge(.detach(leaseID: lease.id, token: lease.token))
            self.lease = nil
        }
    }
}
