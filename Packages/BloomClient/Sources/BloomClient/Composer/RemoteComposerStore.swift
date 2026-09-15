import Foundation
import Observation

/// Loading and saving do not depend on a picker framework. Failed saves keep the acknowledged values.
@MainActor
@Observable
public final class RemoteComposerStore {
    public let sessionID: SessionID
    public private(set) var state: RemoteComposerState?
    public private(set) var isLoading = false
    public private(set) var isApplying = false
    public private(set) var error: String?
    @ObservationIgnored private var service: RemoteWorkspaceService
    @ObservationIgnored private var loadingTask: Task<Void, Never>?
    @ObservationIgnored private var loadingID: UUID?
    @ObservationIgnored private var loadWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var pending: (controls: ComposerControls, id: UUID)?
    public var hasPendingSave: Bool { pending != nil }
    public var pendingControls: ComposerControls? { pending?.controls }
    var loadingWaiterCount: Int { loadWaiters.count }

    public init(service: RemoteWorkspaceService, sessionID: SessionID) {
        self.service = service; self.sessionID = sessionID
    }

    /// The owner verifies the same server origin before replacing a disconnected transport.
    /// Uncertain saves keep their identity; replies from the previous load cannot replace state.
    public func reconnect(using service: RemoteWorkspaceService) throws {
        guard !isApplying else { throw ConnectionRefusal("Wait for the composer settings save to finish.") }
        let waiting = loadWaiters.values
        loadWaiters = [:]
        loadingID = nil
        loadingTask?.cancel()
        loadingTask = nil
        isLoading = false
        self.service = service
        waiting.forEach { $0.resume(throwing: CancellationError()) }
    }

    /// Only after explicit confirmation: forgetting a retry does not undo changes on the server.
    public func discardPendingSave() throws {
        guard !isApplying else { throw ConnectionRefusal("Wait for the composer settings save to finish.") }
        pending = nil
        error = nil
    }

    /// Every caller awaits the same request. Cancelling one caller does not strand the others.
    public func load() async throws {
        guard !isApplying else { throw ConnectionRefusal("Wait for the composer settings save to finish.") }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                loadWaiters[waiterID] = continuation
                guard loadingTask == nil else { return }
                isLoading = true
                let id = UUID()
                loadingID = id
                let service = service
                let sessionID = sessionID
                loadingTask = Task { [weak self] in
                    let result: Result<RemoteComposerState, Error>
                    do { result = .success(try await service.composer(sessionID: sessionID)) } catch { result = .failure(error) }
                    self?.finishLoad(result, id: id)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelLoad(waiterID: waiterID) }
        }
        try Task.checkCancellation()
    }

    private func finishLoad(_ result: Result<RemoteComposerState, Error>, id: UUID) {
        guard loadingID == id else { return }
        let waiting = loadWaiters.values
        loadWaiters = [:]
        loadingID = nil
        loadingTask = nil
        isLoading = false
        switch result {
        case .success(let loaded):
            state = loaded
            error = nil
            waiting.forEach { $0.resume() }
        case .failure(let failure):
            if !(failure is CancellationError) { error = failure.localizedDescription }
            waiting.forEach { $0.resume(throwing: failure) }
        }
    }

    private func cancelLoad(waiterID: UUID) {
        loadWaiters.removeValue(forKey: waiterID)?.resume(throwing: CancellationError())
        guard loadWaiters.isEmpty else { return }
        loadingID = nil
        loadingTask?.cancel()
        loadingTask = nil
        isLoading = false
    }

    /// Retrying the same uncertain save keeps its command ID, including a save that forks a chat.
    public func apply(_ controls: ComposerControls) async throws -> RemoteSession? {
        guard !isLoading, !isApplying, let state else {
            throw ConnectionRefusal("Wait for the current composer settings request to finish.")
        }
        guard pending == nil || pending?.controls == controls else {
            throw ConnectionRefusal("Retry the previous settings save before making another change.")
        }
        if pending == nil {
            guard state.choices.offers(controls.agentKind), controls.agentKind.canRunWorkspaces,
                  !controls.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConnectionRefusal("Choose an available agent and model.")
            }
        }
        isApplying = true
        defer { isApplying = false }
        let id: UUID
        if let pending, pending.controls == controls { id = pending.id } else { id = UUID() }
        pending = (controls, id)
        do {
            let fork = try await service.setComposer(sessionID: sessionID, controls: controls, commandID: id)
            if fork == nil { self.state?.controls = controls }
            pending = nil
            error = nil
            return fork
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
            throw error
        }
    }
}
