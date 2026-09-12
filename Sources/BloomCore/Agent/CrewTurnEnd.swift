import Foundation

/// Both runtimes report failure immediately, but report completion only after queued followups
/// have settled. The wire message and the transcript recording always come from CrewMessage.
public enum CrewTurnEnd: Sendable, Equatable {
    case completed(String)
    case failed(String)
    case cancelled(String)

    public var isFailure: Bool { if case .failed = self { true } else { false } }
    public var summary: String {
        switch self {
        case .completed(let text), .failed(let text), .cancelled(let text): text
        }
    }

    public func report(name: String, continuing: Bool) -> CrewMessage? {
        switch self {
        case .completed(let summary), .cancelled(let summary): continuing ? nil : .stopped(name: name, lastMessage: summary)
        case .failed(let reason): .failed(name: name, reason: reason)
        }
    }
}

/// Claim before awaiting Store or another actor. A result arriving after an error cannot report
/// the same turn twice. Reset only when a new turn actually starts.
public struct CrewTurnReportClaim: Sendable {
    private var claimed = false
    public init() {}
    public mutating func start() { claimed = false }
    public mutating func claim() -> Bool {
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
