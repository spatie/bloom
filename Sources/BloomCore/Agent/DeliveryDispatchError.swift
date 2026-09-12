import Foundation

public enum DeliveryDispatchError: Error, LocalizedError, Sendable {
    case notClaimed
    case processUnavailable

    public var errorDescription: String? {
        switch self {
        case .notClaimed: "This message is no longer waiting to be sent."
        case .processUnavailable: "The agent process could not start. Try again."
        }
    }
}
