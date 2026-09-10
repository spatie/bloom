import Foundation

/// The server drains durable deliveries even when every client is disconnected. A receipt is
/// written before touching stdin: after a crash an uncertain delivery waits for review instead
/// of silently sending the same instruction twice.
actor ServerPromptQueue {
    typealias LoadSession = @Sendable (SessionID) async throws -> ServerSession
    private let store: Store
    private let load: LoadSession
    private var tasks: [SessionID: Task<Void, Never>] = [:]
    private var errors: [SessionID: String] = [:]
    private var closed = false
    private var endings: [SessionID: CrewTurnEnd] = [:]
    private let settled: @Sendable (SessionID, CrewTurnEnd) async -> Void

    init(store: Store, load: @escaping LoadSession,
         settled: @escaping @Sendable (SessionID, CrewTurnEnd) async -> Void = { _, _ in }) {
        self.store = store; self.load = load; self.settled = settled
    }

    func turnEnded(_ id: SessionID, ending: CrewTurnEnd) async {
        guard !closed else { return }
        endings[id] = ending
        if ending.isFailure {
            errors[id] = ending.summary
            try? await store.setSetting(pauseKey(id), "true")
        }
        start(id)
    }

    func restore() async throws {
        for workspace in try await store.workspaces() {
            for session in try await store.sessions(workspaceID: workspace.id) {
                if try await store.setting(pauseKey(session.id)) == "true" {
                    errors[session.id] = "Queue paused. Send a message to resume."
                } else if try await !store.pendingDeliveries(sessionID: session.id).isEmpty { start(session.id) }
            }
        }
    }

    func enqueue(_ text: String, sessionID: SessionID) async throws {
        try await enqueue(Delivery(targetSessionID: sessionID, body: text), resumesPausedQueue: true)
    }

    func enqueue(_ delivery: Delivery, resumesPausedQueue: Bool = false) async throws {
        guard !closed else { throw ServerFailure("The server is shutting down.") }
        let sessionID = delivery.targetSessionID
        _ = try await store.enqueueDelivery(delivery)
        if resumesPausedQueue {
            try await store.setSetting(pauseKey(sessionID), "false")
            errors.removeValue(forKey: sessionID)
        }
        start(sessionID)
    }

    /// A shared Store transaction already inserted this conversation and its initial brief.
    func resumeStoredDeliveries(_ id: SessionID) async throws { try await restartIfPending(id) }

    func snapshot(_ id: SessionID) async throws -> ([ServerQueuedPrompt], String?) {
        let pending = try await store.pendingDeliveries(sessionID: id)
        return (pending.map { ServerQueuedPrompt(id: $0.id, text: $0.body) }, errors[id])
    }

    func cancel(_ deliveryID: DeliveryID, sessionID: SessionID) async throws {
        let task = tasks[sessionID]
        task?.cancel()
        await task?.value
        guard try await store.pendingDeliveries(sessionID: sessionID).contains(where: { $0.id == deliveryID }) else {
            throw ServerFailure("This message has already been sent. Stop the current turn instead.")
        }
        try await store.cancelDelivery(id: deliveryID)
        errors.removeValue(forKey: sessionID)
        try await restartIfPending(sessionID)
    }

    func pause(_ id: SessionID) async throws {
        try await store.setSetting(pauseKey(id), "true")
        let task = tasks[id]
        task?.cancel()
        await task?.value
        errors[id] = "Queue paused. Send a message to resume."
    }

    func shutdown() async {
        closed = true
        let running = Array(tasks.values)
        tasks.removeAll()
        for task in running { task.cancel() }
        for task in running { await task.value }
    }

    private func key(_ delivery: Delivery) -> String { "server.delivery." + delivery.id.rawValue }
    private func pauseKey(_ id: SessionID) -> String { "server.queue.paused." + id.rawValue }

    private func start(_ id: SessionID) {
        guard tasks[id] == nil, !closed else { return }
        tasks[id] = Task {
            await self.drain(id)
            await self.settleTurn(id)
            // An enqueue can arrive while the final empty read is returning from Store.
            // Recheck after releasing the task slot so that delivery cannot be stranded.
            try? await self.restartIfPending(id)
        }
    }

    private func restartIfPending(_ id: SessionID) async throws {
        guard !closed, !Task.isCancelled, errors[id] == nil, tasks[id] == nil,
              try await store.setting(pauseKey(id)) != "true",
              try await !store.pendingDeliveries(sessionID: id).isEmpty else { return }
        start(id)
    }

    private func settleTurn(_ id: SessionID) async {
        guard !closed, let ending = endings.removeValue(forKey: id) else { return }
        await settled(id, ending)
    }

    private func drain(_ id: SessionID) async {
        defer { tasks.removeValue(forKey: id) }
        do {
            while !Task.isCancelled, !closed, errors[id] == nil,
                  try await store.setting(pauseKey(id)) != "true",
                  let delivery = try await store.pendingDeliveries(sessionID: id).first {
                if let receipt = try await store.setting(key(delivery)) {
                    if receipt == "delivered" { try await store.markDelivered(id: delivery.id); continue }
                    errors[id] = "A previous delivery has an uncertain outcome. Check the conversation, then remove that queued message before continuing."
                    return
                }
                let live = try await load(id)
                try await live.refreshState(store: store, sessionID: id)
                if await live.isBusy {
                    try await Task.sleep(for: .milliseconds(200))
                    continue
                }
                // An error or Stop can arrive while loading/observing the live session. Its
                // pause must win even when that session has just become idle.
                guard errors[id] == nil, try await store.setting(pauseKey(id)) != "true" else { return }
                try Task.checkCancellation()
                try await store.setSetting(key(delivery), "started")
                // This followup supersedes a completed turn. A failure pauses above instead.
                endings.removeValue(forKey: id)
                do {
                    // Cancelling the drain pauses the queue, not a runner halfway through launch.
                    let send = Task { try await live.send(delivery.sent, recording: delivery.crewPayload) }
                    try await send.value
                    try await store.setSetting(key(delivery), "delivered")
                    try await store.markDelivered(id: delivery.id)
                } catch {
                    errors[id] = error.localizedDescription
                    return
                }
            }
        } catch {
            if !Task.isCancelled {
                errors[id] = error.localizedDescription
                if endings[id] == nil { endings[id] = .failed(error.localizedDescription) }
                try? await store.setSetting(pauseKey(id), "true")
            }
        }
    }
}

public struct ServerQueuedPrompt: Codable, Sendable, Identifiable {
    public var id: DeliveryID
    public var text: String
}
