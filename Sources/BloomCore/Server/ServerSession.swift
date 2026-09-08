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

    init(runner: any SessionRunner) { self.runner = runner }

    func send(_ text: String) async throws {
        guard !isClosed else { throw ServerFailure("This session is closed.") }
        guard !isBusy else { throw ServerFailure("The agent is busy. Wait for it to finish or stop it first.") }
        isBusy = true
        isSending = true
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
            try await runner.send(text)
        } catch {
            isBusy = false
            throw error
        }
    }

    private func receive(_ event: AgentEvent) {
        switch event {
        case .streamDelta(.text(let text)):
            // The durable transcript remains complete; only the transient tail is bounded.
            streamingText += text
            if streamingText.utf8.count > 262_144 { streamingText = String(streamingText.suffix(65_536)) }
        case .assistantText:
            streamingText = ""
        case .result, .error:
            isBusy = false
            streamingText = ""
        default: break
        }
    }

    func stop() {
        // Keep the turn reserved until its terminal event. A late stop must not cancel a new turn.
        guard isBusy else { return }
        runner.cancelNow()
    }

    func refreshState(store: Store, sessionID: SessionID) async throws {
        guard isBusy, !isSending else { return }
        let observedGeneration = generation
        let session = try await store.session(id: sessionID)
        guard isBusy, !isSending, generation == observedGeneration else { return }
        if let session, [.cancelled, .idle, .failed].contains(session.state) {
            isBusy = false
            streamingText = ""
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
