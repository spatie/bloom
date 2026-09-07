import Foundation

/// A short, absolute-time arrival shared by the temporary and persisted drawings of a message.
/// A new view resumes the same curve instead of starting another fade when SQLite catches up.
public struct MessageArrival: Hashable, Sendable {
    public enum Style: Hashable, Sendable { case sent, reply }

    public let style: Style
    public let startedAt: Date

    public init(style: Style, startedAt: Date = Date()) {
        self.style = style
        self.startedAt = startedAt
    }

    public var duration: TimeInterval { style == .sent ? 0.32 : 0.22 }

    public func remaining(at date: Date) -> TimeInterval {
        max(0, duration - max(0, date.timeIntervalSince(startedAt)))
    }

    public struct Pose: Equatable, Sendable {
        public let opacity: Double
        public let rise: Double
        public let scale: Double

        public static let settled = Pose(opacity: 1, rise: 0, scale: 1)
    }

    public func pose(at date: Date, reduceMotion: Bool) -> Pose {
        guard !reduceMotion else { return .settled }
        let fraction = min(1, max(0, date.timeIntervalSince(startedAt) / duration))
        // A cubic ease out, with no overshoot or moving layout dimensions.
        let remainder = pow(1 - fraction, 3)
        return Pose(
            opacity: 1 - remainder,
            rise: style == .sent ? 10 * remainder : 0,
            scale: style == .sent ? 1 - 0.025 * remainder : 1
        )
    }
}

/// Ephemeral presentation state, never loaded from history or written into agent messages.
/// Only live model events call this. The row cache is bounded even in a days-long conversation.
public struct MessageArrivals: Sendable {
    private var deliveries: [DeliveryID: MessageArrival] = [:]
    private var streams: [MessageKind: MessageArrival] = [:]
    private var rows: [Int: MessageArrival] = [:]

    public init() {}

    public mutating func sent(_ id: DeliveryID, at date: Date = Date()) {
        deliveries = deliveries.filter { $0.value.remaining(at: date) > 0 }
        deliveries[id] = MessageArrival(style: .sent, startedAt: date)
    }

    public func delivery(_ id: DeliveryID) -> MessageArrival? { deliveries[id] }
    public func row(_ seq: Int) -> MessageArrival? { rows[seq] }
    public func stream(_ kind: MessageKind) -> MessageArrival? { streams[kind] }

    public mutating func beganStream(_ kind: MessageKind, at date: Date = Date()) {
        guard kind == .assistantText || kind == .thinking else { return }
        streams[kind] = MessageArrival(style: .reply, startedAt: date)
    }

    public mutating func persisted(
        seq: Int, kind: MessageKind, sending: DeliveryID? = nil, at date: Date = Date()
    ) {
        rows = rows.filter { $0.value.remaining(at: date) > 0 }
        switch kind {
        case .user:
            if let sending {
                // An expired queued arrival must not restart when it finally goes to the agent.
                rows[seq] = deliveries.removeValue(forKey: sending)
            } else {
                rows[seq] = MessageArrival(style: .sent, startedAt: date)
            }
        case .assistantText, .thinking:
            rows[seq] = streams.removeValue(forKey: kind)
                ?? MessageArrival(style: .reply, startedAt: date)
        default: break
        }
        if rows.count > 64 {
            for key in rows.keys.sorted().prefix(rows.count - 64) { rows[key] = nil }
        }
    }
}
