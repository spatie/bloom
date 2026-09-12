import Foundation

/// A connection does not own this actor. The server retains it until explicitly shut down,
/// so disconnecting every client cannot cancel an agent or abandon a permission request.
actor ServerSession {
    let runner: any SessionRunner
    private(set) var isBusy = false
    private(set) var streamingText = ""
    private var eventTask: Task<Void, Never>?
    private var isClosed = false
    private var isSending = false
    private var generation = 0
    private var answering: Set<String> = []
    private let onTurnEnded: @Sendable (CrewTurnEnd) async -> Void
    private var turnReportClaim = CrewTurnReportClaim()
    private var wasStopped = false

    init(runner: any SessionRunner, onTurnEnded: @escaping @Sendable (CrewTurnEnd) async -> Void = { _ in }) { self.runner = runner; self.onTurnEnded = onTurnEnded }

    func send(_ text: String, recording: Data? = nil) async throws {
        guard !isClosed else { throw ServerFailure("This session is closed.") }
        guard !isBusy else { throw ServerFailure("The agent is busy. Wait for it to finish or stop it first.") }
        isBusy = true
        isSending = true
        wasStopped = false
        turnReportClaim.start()
        generation += 1
        defer { isSending = false }
        streamingText = ""
        if eventTask == nil {
            let events = runner.events
            eventTask = Task { [weak self] in
                for await event in events {
                    guard !Task.isCancelled else { break }
                    await self?.receive(event)
                }
            }
        }
        do {
            try await runner.send(text, recording: recording)
        } catch {
            if turnReportClaim.claim() { await onTurnEnded(wasStopped ? .cancelled(error.localizedDescription) : .failed(error.localizedDescription)) }
            isBusy = false
            throw error
        }
    }

    private func receive(_ event: AgentEvent) async {
        switch event {
        case .streamDelta(.text(let text)):
            // The durable transcript remains complete; only the transient tail is bounded.
            streamingText += text
            if streamingText.utf8.count > 262_144 { streamingText = String(streamingText.suffix(65_536)) }
        case .assistantText:
            streamingText = ""
        case .result(let result):
            guard turnReportClaim.claim() else { return }
            streamingText = ""
            await onTurnEnded(wasStopped ? .cancelled(result.summary) : .completed(result.summary))
            isBusy = false
        case .error(let error):
            guard turnReportClaim.claim() else { return }
            streamingText = ""
            await onTurnEnded(wasStopped ? .cancelled(error.message) : .failed(error.message))
            isBusy = false
        default: break
        }
    }

    func stop() {
        // Keep the turn reserved until its terminal event. A late stop must not cancel a new turn.
        guard isBusy else { return }
        wasStopped = true
        runner.cancelNow()
    }

    func refreshState(store: Store, sessionID: SessionID) async throws {
        guard isBusy, !isSending else { return }
        let observedGeneration = generation
        let session = try await store.session(id: sessionID)
        guard isBusy, !isSending, generation == observedGeneration else { return }
        // A stored idle/failed row can beat its terminal event to this actor. Releasing the
        // turn here would let a queued send start before that old event arrives. Only explicit
        // Stop has a backend that may finish without a result event (Claude SIGTERM).
        if let session, session.state == .cancelled, wasStopped {
            streamingText = ""
            if turnReportClaim.claim() { await onTurnEnded(.cancelled("")) }
            isBusy = false
        }
    }

    func answer(requestID: String, decision: PermissionDecision, store: Store, sessionID: SessionID) async throws {
        guard !isClosed, !answering.contains(requestID) else {
            throw ServerFailure("This question has already been answered.")
        }
        answering.insert(requestID)
        defer { answering.remove(requestID) }
        let pending = try await store.pendingPermissionAsks(sessionID: sessionID)
        guard let question = pending.first(where: { $0.requestID == requestID }), !isClosed else {
            throw ServerFailure("This question is no longer waiting for an answer.")
        }
        if case .approvePlan(let mode) = decision {
            guard question.ask.isPlanApproval, PlanApproval.modes.contains(mode) else { throw ServerFailure("This question cannot approve implementation in that mode.") }
        }
        await runner.answer(requestID: requestID, decision: decision)
    }

    func shutdown() async {
        isClosed = true
        runner.terminateNow()
        // The runner escalates to SIGKILL on its own budget. Keep the server process alive long
        // enough for that task to run rather than orphaning a CLI that ignored SIGTERM.
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while await runner.isProcessAlive, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        eventTask?.cancel()
        eventTask = nil
    }

    deinit {
        runner.terminateNow()
        eventTask?.cancel()
    }
}
