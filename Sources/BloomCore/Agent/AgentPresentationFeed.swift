import Foundation
import Synchronization

public struct AgentPresentationBatch: Sendable {
    public let revision: UInt64
    public let events: [AgentEvent]
    public let eventRevisions: [UInt64]
    public let messageSequences: [Int?]
    public let failure: String?
    public let recovery: AgentPresentationRecovery?
}

/// The durable transcript remains in Store. This is only the current live projection needed
/// when a slow window has fallen behind the bounded event window.
public struct AgentPresentationRecovery: Sendable {
    public let text: String
    public let thinking: String
    public let toolName: String?
    public let status: String?
    public let thinkingTokens: Int
    public let subagents: SubagentRoster
    public let stateEvent: AgentEvent?
    public let stateRevision: UInt64
    public let retry: AgentRetry?
    public let quota: Data?
}

/// A subscriber queues one wake-up, never an unbounded copy of provider output. The shared
/// replay window has both an item and byte budget. Overflow recovers the live projection and
/// reloads durable rows, rather than dropping text deltas or blocking protocol ingestion.
public final class AgentPresentationFeed: Sendable {
    private struct Entry: Sendable {
        let revision: UInt64
        let event: AgentEvent
        let bytes: Int
        let messageSeq: Int?
    }
    private struct State: Sendable {
        var lastActivity = ContinuousClock.now
        var revision: UInt64 = 0
        var entries: [Entry] = []
        var bytes = 0
        var text = ""
        var thinking = ""
        var toolName: String?
        var status: String?
        var thinkingTokens = 0
        var subagents = SubagentRoster()
        var stateEvent: AgentEvent?
        var stateRevision: UInt64 = 0
        var latestStartRevision: UInt64 = 0
        var isTurnRunning = false
        var retry: AgentRetry?
        var quota: Data?
        var subscribers: [UUID: AsyncStream<UInt64>.Continuation] = [:]
        var acknowledged: [UUID: UInt64] = [:]
        var failure: String?
        var finished = false
    }
    private let state = Mutex(State())
    private let raw = EventFanout<AgentEvent>()
    private let lifecycle: AgentLifecycleSpool
    private let maxItems: Int
    private let maxBytes: Int

    public init(maxItems: Int = 512, maxBytes: Int = 8 * 1_024 * 1_024, lifecycleCapacity: Int = 64 * 1_024 * 1_024) {
        lifecycle = AgentLifecycleSpool(capacity: lifecycleCapacity)
        self.maxItems = max(1, maxItems)
        self.maxBytes = max(1, maxBytes)
    }

    /// Compatibility for non-UI consumers. The window uses notifications and read(after:).
    public func stream() -> AsyncStream<AgentEvent> { raw.stream() }

    public func notifications(id: UUID = UUID(), after cursor: UInt64? = nil) -> AsyncStream<UInt64> {
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.onTermination = { [weak self] reason in
                if case .cancelled = reason { self?.unregister(id) }
            }
            let initial = state.withLock { value -> (Bool, UInt64) in
                guard !value.finished else { return (false, value.revision) }
                value.subscribers[id] = continuation
                value.acknowledged[id] = cursor ?? value.revision
                return (true, value.revision)
            }
            if initial.0 { continuation.yield(initial.1) } else { continuation.finish() }
        }
    }

    public func yield(_ event: AgentEvent, messageSeq: Int? = nil) {
        let targets = state.withLock { value -> ([AsyncStream<UInt64>.Continuation], UInt64) in
            guard !value.finished else { return ([], value.revision) }
            value.lastActivity = ContinuousClock.now
            value.revision += 1
            if value.failure == nil {
                do { try lifecycle.append(event, revision: value.revision, messageSeq: messageSeq) } catch {
                    value.failure = error.localizedDescription
                }
            }
            let bytes = Self.size(of: event)
            value.entries.append(Entry(revision: value.revision, event: event, bytes: bytes, messageSeq: messageSeq))
            value.bytes += bytes
            while value.entries.count > maxItems || value.bytes > maxBytes {
                value.bytes -= value.entries.removeFirst().bytes
            }
            switch event {
            case .streamDelta(.text(let text)): value.text += text
            case .streamDelta(.thinking(let text)): value.thinking += text
            case .streamDelta(.toolName(let name)): value.toolName = name
            case .status(let status): value.status = status
            case .thinkingTokens(let tokens): value.thinkingTokens = tokens
            case .subagent(let signal): value.subagents.apply(signal)
            case .retrying(let retry): value.retry = retry
            case .rateLimit(let quota): value.quota = quota
            case .initialized, .result, .error:
                value.stateEvent = event
                value.stateRevision = value.revision
                value.text = ""
                value.thinking = ""
                value.toolName = nil
                value.retry = nil
                value.status = nil
                if case .initialized = event {
                    value.latestStartRevision = value.revision
                    value.isTurnRunning = true
                    value.subagents.turnStarted()
                } else { value.isTurnRunning = false }
                if case .error = event { value.subagents.agentExited() }
            case .assistantText, .thinking, .toolUse, .toolResult, .permissionAsk:
                value.text = ""
                value.thinking = ""
                value.toolName = nil
                value.retry = nil
            default: break
            }
            return (Array(value.subscribers.values), value.revision)
        }
        raw.yield(event)
        for target in targets.0 { target.yield(targets.1) }
    }

    public func snapshot() -> AgentPresentationBatch {
        state.withLock { value in
            AgentPresentationBatch(revision: value.revision, events: [], eventRevisions: [], messageSequences: [], failure: value.failure, recovery: AgentPresentationRecovery(
                text: value.text, thinking: value.thinking, toolName: value.toolName,
                status: value.status, thinkingTokens: value.thinkingTokens,
                subagents: value.subagents, stateEvent: value.stateEvent,
                stateRevision: value.stateRevision, retry: value.retry, quota: value.quota
            ))
        }
    }

    public func read(after cursor: UInt64) -> AgentPresentationBatch {
        state.withLock { value in
            let first = value.entries.first?.revision ?? (value.revision + 1)
            let missed = cursor < value.revision && cursor + 1 < first
            let recovery = missed ? AgentPresentationRecovery(
                text: value.text, thinking: value.thinking, toolName: value.toolName,
                status: value.status, thinkingTokens: value.thinkingTokens,
                subagents: value.subagents, stateEvent: value.stateEvent,
                stateRevision: value.stateRevision, retry: value.retry, quota: value.quota
            ) : nil
            return AgentPresentationBatch(revision: value.revision,
                events: missed ? [] : value.entries.filter { $0.revision > cursor }.map(\.event),
                eventRevisions: missed ? [] : value.entries.filter { $0.revision > cursor }.map(\.revision),
                messageSequences: missed ? [] : value.entries.filter { $0.revision > cursor }.map(\.messageSeq),
                failure: value.failure, recovery: recovery)
        }
    }

    public func lifecycleEvents(after cursor: UInt64, through revision: UInt64, limit: Int = 32) throws -> [AgentLifecycleEntry] {
        try lifecycle.read(after: cursor, through: revision, limit: limit)
    }

    public func lifecyclePage(after cursor: UInt64, through revision: UInt64) async throws -> [AgentLifecycleEntry] {
        try await Task.detached { [self] in
            try lifecycleEvents(after: cursor, through: revision)
        }.value
    }

    public func acknowledgePage(subscriber id: UUID, through revision: UInt64) async {
        await Task.detached { [self] in acknowledge(subscriber: id, through: revision) }.value
    }

    public func acknowledge(subscriber id: UUID, through revision: UInt64) {
        let cursor = state.withLock { value -> UInt64? in
            guard let current = value.acknowledged[id] else { return nil }
            value.acknowledged[id] = max(current, revision)
            return value.acknowledged.values.min()
        }
        if let cursor { reclaim(through: cursor) }
    }

    public func unsubscribe(_ id: UUID) { unregister(id) }

    private func unregister(_ id: UUID) {
        let cursor = state.withLock { value in
            value.subscribers[id] = nil
            value.acknowledged[id] = nil
            return value.acknowledged.values.min() ?? value.revision
        }
        reclaim(through: cursor)
        if state.withLock({ $0.finished && $0.acknowledged.isEmpty }) { lifecycle.close() }
    }

    private func reclaim(through revision: UInt64) {
        do {
            try lifecycle.acknowledge(through: revision)
            if state.withLock({ $0.finished && revision >= $0.revision }) { lifecycle.close() }
        } catch {
            state.withLock { $0.failure = error.localizedDescription }
        }
    }

    public var isTurnRunning: Bool { state.withLock { $0.isTurnRunning } }
    public func hasLaterTurn(than revision: UInt64) -> Bool {
        state.withLock { $0.latestStartRevision > revision }
    }

    public var retainedLifecycleBytes: UInt64 { lifecycle.retainedBytes }

    public var retainedUsage: (items: Int, bytes: Int) {
        state.withLock { ($0.entries.count, $0.bytes) }
    }

    public func noteProcessEnded() {
        let notification = state.withLock { value in
            value.subagents.agentExited()
            value.isTurnRunning = false
            value.revision += 1
            value.entries = []
            value.bytes = 0
            value.text = ""
            value.thinking = ""
            value.toolName = nil
            value.status = nil
            return (Array(value.subscribers.values), value.revision)
        }
        for target in notification.0 { target.yield(notification.1) }
    }

    public var lastActivity: ContinuousClock.Instant { state.withLock { $0.lastActivity } }
    public func noteActivity() { state.withLock { $0.lastActivity = .now } }

    public var hasBackgroundWork: Bool { state.withLock { $0.subagents.isWorking } }

    public func finish() {
        let targets = state.withLock { value in
            value.finished = true
            let targets = Array(value.subscribers.values)
            value.subscribers = [:]
            value.entries = []
            value.bytes = 0
            return targets
        }
        if state.withLock({ $0.acknowledged.isEmpty }) { lifecycle.close() }
        raw.finish()
        for target in targets { target.finish() }
    }

    private static func size(of event: AgentEvent) -> Int {
        switch event {
        case .streamDelta(.text(let value)), .streamDelta(.thinking(let value)),
             .streamDelta(.toolName(let value)), .streamDelta(.toolInput(let value)), .status(let value):
            return value.utf8.count + 64
        case .subagent(let signal): return String(describing: signal).utf8.count + 256
        case .result(let result): return event.raw.count + result.summary.utf8.count + 256
        case .error(let error): return event.raw.count + error.message.utf8.count + 256
        default: return event.raw.count * 2 + 256
        }
    }
}
