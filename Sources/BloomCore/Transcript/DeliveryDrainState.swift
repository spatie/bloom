/// Coalesces requests made while a delivery awaits its runner, without allowing two senders.
public enum DeliveryDrainState: Sendable {
    case idle
    case active
    case requested

    public mutating func begin() -> Bool {
        guard case .idle = self else {
            self = .requested
            return false
        }
        self = .active
        return true
    }

    public mutating func finish() -> Bool {
        let again = self == .requested
        self = .idle
        return again
    }
}
